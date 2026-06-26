package interceptor

import (
	"bytes"
	"crypto/tls"
	"errors"
	"interceptor-grpc/config"
	"interceptor-grpc/crController"
	"io"
	"net/http"
	"strconv"
	"sync"
	"time"

	"github.com/rs/zerolog/log"
)

var lock = &sync.RWMutex{}
var singleInstance *http.Client

// drainSlots limita a concorrência da drenagem da fila (replay pós-recuperação
// pode ter dezenas de milhares de entradas; sem limite inundaria a aplicação).
var drainSlots = make(chan struct{}, 32)

// Tempo máximo que um request enfileirado espera o ciclo de recuperação
// (snapshot/restore + drenagem da fila). Igual ao timeout do spin-gate.
const queueWaitTimeout = 5 * time.Minute

// QueueHttpRequest carrega uma CÓPIA do request (nunca o *http.Request ou o
// ResponseWriter vivos, que morrem quando o handler retorna). RespCh != nil
// significa que há um handler bloqueado esperando o resultado pra responder
// ao cliente; nil significa replay-only (cliente já foi respondido).
type QueueHttpRequest struct {
	Data   config.RequestData
	RespCh chan config.Result
}

func ProcessQueue() {
	for {
		time.Sleep(50 * time.Millisecond)

		// Skip processing if container is unavailable, but don't exit the loop
		if crController.IsContainerUnavailable.Load() {
			crController.IsRunningPendingRequestQueue.Store(false)
			continue
		}

		// Skip if queue is empty, but keep the loop running
		if QueueLength.Load() == 0 {
			crController.IsRunningPendingRequestQueue.Store(false)
			continue
		}

		// Skip if snapshot or restore is in progress
		if crController.IsDoingSnapshot.Load() || crController.IsRestoringSnapshot.Load() {
			continue
		}

		// Drena a fila inteira, não 1 item por tick: após uma recuperação o
		// replay pode enfileirar dezenas de milhares de entradas, e 1/50ms
		// (20/s) não escala. Concorrência limitada por drainSlots pra não
		// inundar a aplicação.
		for QueueLength.Load() > 0 {
			if crController.IsDoingSnapshot.Load() || crController.IsRestoringSnapshot.Load() ||
				crController.IsContainerUnavailable.Load() {
				break
			}
			request, err := GetRequestFromQueue()
			if err != nil {
				break
			}
			crController.IsRunningPendingRequestQueue.Store(true)

			drainSlots <- struct{}{}
			crController.InFlightRequests.Add(1)
			go func(item QueueHttpRequest) {
				defer func() {
					<-drainSlots
					crController.InFlightRequests.Done()
				}()
				res := forwardBuffered(item.Data)
				if item.RespCh != nil {
					// Canal buffered(1): se o handler já desistiu (timeout/
					// desconexão), o send não bloqueia e o resultado é descartado.
					item.RespCh <- res
				}
			}(request)
		}
	}
}

func Handler(w http.ResponseWriter, r *http.Request) {
	startTime := time.Now()
	timeout := 5 * time.Minute

	for crController.IsDoingSnapshot.Load() ||
		crController.IsRestoringSnapshot.Load() ||
		crController.IsContainerUnavailable.Load() {
		if time.Since(startTime) > timeout {
			http.Error(w, "request timed out while waiting for container to be available", http.StatusBadGateway)
			return
		}
		time.Sleep(50 * time.Millisecond)
	}

	// Copia o request inteiro aqui: o *http.Request e o ResponseWriter só são
	// válidos enquanto este handler está vivo, então nada fora desta função
	// (fila, buffer de reprocess) pode segurá-los.
	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "error reading request body", http.StatusInternalServerError)
		return
	}
	data := config.RequestData{
		Method: r.Method,
		Path:   r.URL.Path,
		Query:  r.URL.RawQuery,
		Header: r.Header.Clone(),
		Body:   body,
	}

	if crController.IsUnavailable() {
		// Fila de recuperação: o handler fica bloqueado esperando o resultado
		// pelo canal — é ele quem escreve a resposta, nunca o worker. Sem isso
		// o net/http finaliza a resposta como 200 vazio assim que o handler
		// retorna, e o worker escreveria num writer morto.
		respCh := make(chan config.Result, 1)
		AddRequestToQueue(QueueHttpRequest{Data: data, RespCh: respCh})
		select {
		case res := <-respCh:
			writeResult(w, res)
		case <-r.Context().Done():
			// Cliente desconectou. O worker ainda aplica o request (estado);
			// o canal buffered absorve o resultado sem bloquear ninguém.
		case <-time.After(queueWaitTimeout):
			http.Error(w, "timed out waiting for recovery queue", http.StatusGatewayTimeout)
		}
		return
	}

	crController.InFlightRequests.Add(1)
	defer crController.InFlightRequests.Done()
	writeResult(w, forwardBuffered(data))
}

// forwardBuffered registra o request no buffer de reprocess, encaminha pra
// aplicação e marca como processado. GET/HEAD não mutam estado: vão direto,
// sem entrar no buffer (replay de leituras seria inútil e incharia o buffer
// entre snapshots).
func forwardBuffered(data config.RequestData) config.Result {
	if data.Method == http.MethodGet || data.Method == http.MethodHead {
		return sendRequest(data, 0)
	}
	requestNumber := config.SaveRequestToBuffer(data)
	res := sendRequest(data, requestNumber)
	config.UpdateRequestToProcessed(requestNumber)
	return res
}

func writeResult(w http.ResponseWriter, res config.Result) {
	w.WriteHeader(res.Status)
	if len(res.Body) > 0 {
		if _, err := w.Write(res.Body); err != nil {
			log.Err(err).Msg("Error writing response")
		}
	}
}

func sendRequest(data config.RequestData, uuid uint64) config.Result {
	client := getHttpClient()

	baseURL := config.GetApplicationURL()
	if direct := config.GetDirectApplicationURL(); direct != "" {
		baseURL = direct
	}
	fullPath := baseURL + data.Path + "?" + data.Query

	req, err := http.NewRequest(data.Method, fullPath, bytes.NewReader(data.Body))
	if err != nil {
		log.Err(err).Msg("Error creating request")
		return config.Result{Status: 500}
	}
	for name, values := range data.Header {
		for _, value := range values {
			req.Header.Add(name, value)
		}
	}
	req.Header.Set("Interceptor-Controller", strconv.FormatUint(uuid, 10))

	resp, err := client.Do(req)
	if err != nil {
		log.Err(err).Msg("Error sending request")
		return config.Result{Status: 500}
	}
	body, err := getBodyContent(resp)
	closeErr := resp.Body.Close()
	if err != nil {
		log.Err(err).Msg("Error getting body content")
		return config.Result{Status: 500}
	}
	if closeErr != nil {
		log.Err(closeErr).Msg("Error closing response body")
		return config.Result{Status: 500}
	}
	return config.Result{Status: resp.StatusCode, Body: body}
}

func getHttpClient() *http.Client {
	if singleInstance == nil {
		lock.Lock()
		if singleInstance == nil {
			tr := &http.Transport{
				MaxIdleConns: 0,
				// 4096 (era 200): no flush pós-snapshot o interceptor abre
				// milhares de conexões simultâneas pro kv; com pool pequeno o
				// excedente é FECHADO após o uso e vira TIME_WAIT (60s) no
				// lado do interceptor → as ~28K portas efêmeras do pod esgotam
				// (EADDRNOTAVAIL) e até health/canário param de conseguir
				// discar. Pool grande = reuso em vez de churn.
				MaxIdleConnsPerHost: 4096,
				IdleConnTimeout:     90 * time.Second,
				DisableCompression:  true,
				TLSClientConfig:     &tls.Config{InsecureSkipVerify: true},
				// Keep-alive ativo durante operação normal para evitar overhead de
				// TCP handshake por request. Conexões são drenadas explicitamente em
				// DrainConnections() antes de cada checkpoint (CRIU requer zero
				// conexões TCP abertas no momento do dump).
				DisableKeepAlives: false,
			}
			singleInstance = &http.Client{Transport: tr}
		}
		lock.Unlock()
	}
	return singleInstance
}

// DrainConnections fecha todas as conexões keep-alive do pool antes do checkpoint.
// Chamado via callback registrado em crController.RegisterDrainConnectionsCallback.
func DrainConnections() {
	lock.Lock()
	defer lock.Unlock()
	if singleInstance != nil {
		singleInstance.CloseIdleConnections()
		singleInstance = nil // novo cliente criado pos-restore
	}
}

func getBodyContent(response *http.Response) ([]byte, error) {
	body, err := io.ReadAll(response.Body)
	if err != nil {
		log.Err(err).Msg("Error reading response body")
		return nil, errors.New("error parsing request body")
	}
	return body, nil
}
