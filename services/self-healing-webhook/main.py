#!/usr/bin/env python3
# =============================================================================
# Self-Healing Webhook — ToggleMaster Fase 4
# ---------------------------------------------------------------------------
# Recebe webhooks do Alertmanager E do PagerDuty (configurável) e executa
# uma ação corretiva: `kubectl rollout restart deployment/<service>`.
#
# Decisão de design: USAR a API K8s NATIVA (kubernetes client) ao invés de
# shellar `kubectl`. Razão:
#   1) Não precisamos enfiar kubectl + permissões dentro da imagem.
#   2) A biblioteca já lida com retry, paginação e auth in-cluster.
#   3) Token do ServiceAccount montado em /var/run/secrets/k8s/ -> RBAC do K8s.
#
# Auditoria: TUDO que o webhook faz é logado em formato JSON (1 linha por
# evento) para ser pego pelo Loki. Isso serve como prova de execução
# automática (requisito da Fase 4: "Mostre o log/execução da automação").
#
# Segurança em runtime:
#   - Aceita apenas alertas com label "auto_heal: true" (whitelist por design)
#   - Só restarta deployments dos namespaces *-namespace (regex hardcoded)
#   - Rate-limit: máximo 1 restart por deployment a cada 5 minutos
#     (evita "self-DDoS" se o alerta ficar oscilando)
# =============================================================================

import json
import logging
import os
import re
import sys
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from threading import Lock

from kubernetes import client, config
from kubernetes.client.rest import ApiException

# -----------------------------------------------------------------------------
# Logging em JSON (1 evento = 1 linha) — formato escolhido para o Loki indexar
# -----------------------------------------------------------------------------
class JsonFormatter(logging.Formatter):
    def format(self, record):
        payload = {
            "ts": datetime.now(timezone.utc).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "msg": record.getMessage(),
            "service": "self-healing-webhook",
        }
        # Anexa qualquer "extra" passado em log.info(..., extra={...})
        if hasattr(record, "extra_data"):
            payload.update(record.extra_data)
        return json.dumps(payload, ensure_ascii=False)


handler = logging.StreamHandler(sys.stdout)
handler.setFormatter(JsonFormatter())
log = logging.getLogger("self-heal")
log.setLevel(logging.INFO)
log.addHandler(handler)

# -----------------------------------------------------------------------------
# Config
# -----------------------------------------------------------------------------
ALLOWED_NS_REGEX = re.compile(
    os.getenv(
        "ALLOWED_NAMESPACE_REGEX",
        r"^(auth|evaluation|flag|targeting|analytics)-namespace$",
    )
)
# Default: 1 restart por deployment a cada 5 min
RATE_LIMIT_SECONDS = int(os.getenv("RATE_LIMIT_SECONDS", "300"))
LISTEN_PORT = int(os.getenv("LISTEN_PORT", "8080"))

# -----------------------------------------------------------------------------
# Estado em memória do rate-limiter
# Persistência? Não. Se o pod restartar, o limit "esquece" — é aceitável:
# o objetivo do rate-limit é EVITAR flapping em segundos, não enforcar SLA.
# -----------------------------------------------------------------------------
_recent_actions: dict[str, float] = {}
_lock = Lock()


def _within_rate_limit(deployment_key: str) -> bool:
    """True se este deployment foi restartado RECENTEMENTE (não pode de novo)."""
    with _lock:
        last = _recent_actions.get(deployment_key, 0)
        if time.time() - last < RATE_LIMIT_SECONDS:
            return True
        _recent_actions[deployment_key] = time.time()
        return False


# -----------------------------------------------------------------------------
# K8s client (in-cluster: usa o token do SA montado em /var/run/secrets)
# -----------------------------------------------------------------------------
try:
    config.load_incluster_config()
    log.info("k8s_config_loaded", extra={"extra_data": {"mode": "in-cluster"}})
except config.ConfigException:
    # Fallback útil pra rodar em laptop com KUBECONFIG
    config.load_kube_config()
    log.info("k8s_config_loaded", extra={"extra_data": {"mode": "kubeconfig"}})

apps_v1 = client.AppsV1Api()


def restart_deployment(namespace: str, deployment: str) -> tuple[bool, str]:
    """
    Faz o equivalente de `kubectl rollout restart deployment/<name>`:
    altera a anotação `kubectl.kubernetes.io/restartedAt` no PodTemplate.
    Isso força o K8s a criar uma nova ReplicaSet (rolling restart).
    """
    if not ALLOWED_NS_REGEX.match(namespace):
        return False, f"namespace {namespace!r} fora da whitelist"

    deployment_key = f"{namespace}/{deployment}"
    if _within_rate_limit(deployment_key):
        return False, f"rate-limited ({RATE_LIMIT_SECONDS}s) para {deployment_key}"

    timestamp = datetime.now(timezone.utc).isoformat()
    patch = {
        "spec": {
            "template": {
                "metadata": {
                    "annotations": {
                        "kubectl.kubernetes.io/restartedAt": timestamp,
                        "togglemaster.io/restarted-by": "self-healing-webhook",
                    }
                }
            }
        }
    }
    try:
        apps_v1.patch_namespaced_deployment(
            name=deployment, namespace=namespace, body=patch
        )
        return True, f"deployment {deployment_key} restart triggered at {timestamp}"
    except ApiException as e:
        return False, f"k8s API erro {e.status}: {e.reason}"


# -----------------------------------------------------------------------------
# HTTP handler
# -----------------------------------------------------------------------------
class WebhookHandler(BaseHTTPRequestHandler):
    """
    Aceita 2 formatos:
      a) Alertmanager v4 (POST /heal) -> JSON com .alerts[]
      b) Health check (GET /health)
    """

    # Silencia o log padrão (já temos o nosso JSON)
    def log_message(self, *args, **kwargs):
        pass

    def _respond(self, status: int, body: dict):
        payload = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if self.path == "/health":
            self._respond(200, {"status": "ok"})
        else:
            self._respond(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/heal":
            self._respond(404, {"error": "not found"})
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length).decode("utf-8")
            payload = json.loads(body) if body else {}
        except (ValueError, json.JSONDecodeError) as e:
            log.warning(
                "invalid_payload",
                extra={"extra_data": {"error": str(e)}},
            )
            self._respond(400, {"error": f"invalid JSON: {e}"})
            return

        # Formato Alertmanager: { "alerts": [{ "labels": {...}, "status": "..." }, ...] }
        alerts = payload.get("alerts", [])
        if not alerts:
            log.info("no_alerts_in_payload", extra={"extra_data": {"payload": payload}})
            self._respond(200, {"status": "ok", "actions": []})
            return

        actions = []
        for alert in alerts:
            labels = alert.get("labels", {})
            status = alert.get("status", "")

            # Só agimos em alertas FIRING (não em "resolved")
            if status != "firing":
                continue

            # Só restartamos quando o autor do alerta pediu (auto_heal: true)
            if labels.get("auto_heal") != "true":
                continue

            service = labels.get("service") or labels.get("job")
            namespace = labels.get("namespace")
            alertname = labels.get("alertname", "?")

            if not service or not namespace:
                log.warning(
                    "alert_missing_labels",
                    extra={"extra_data": {"labels": labels}},
                )
                continue

            ok, detail = restart_deployment(namespace, service)
            entry = {
                "alertname": alertname,
                "service": service,
                "namespace": namespace,
                "action": "rollout-restart",
                "ok": ok,
                "detail": detail,
            }
            actions.append(entry)
            # Este log é a PROVA da automação para o vídeo da Fase 4
            log.info("auto_heal_executed", extra={"extra_data": entry})

        self._respond(200, {"status": "ok", "actions": actions})


def main():
    server = HTTPServer(("0.0.0.0", LISTEN_PORT), WebhookHandler)
    log.info(
        "webhook_listening",
        extra={
            "extra_data": {
                "port": LISTEN_PORT,
                "allowed_ns_regex": ALLOWED_NS_REGEX.pattern,
                "rate_limit_seconds": RATE_LIMIT_SECONDS,
            }
        },
    )
    server.serve_forever()


if __name__ == "__main__":
    main()
