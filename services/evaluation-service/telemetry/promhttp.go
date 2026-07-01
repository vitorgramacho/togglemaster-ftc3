// promhttp helper para servir /metrics localmente.
// Usa o handler default do prometheus_client/promhttp.
package telemetry

import (
	"net/http"

	"github.com/prometheus/client_golang/prometheus/promhttp"
)

func promhttpHandler() http.Handler {
	return promhttp.Handler()
}
