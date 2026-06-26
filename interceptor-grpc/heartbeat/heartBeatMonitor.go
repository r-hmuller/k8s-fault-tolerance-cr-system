package heartbeat

import (
	"errors"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"syscall"
	"time"

	"interceptor-grpc/config"
	"interceptor-grpc/crController"

	"github.com/rs/zerolog/log"
)

// Timeout explícito: sem ele, um GET de health pendurado num backend saturado
// trava o loop do monitor (e lentidão viraria "falha" só quando a conexão
// caísse, de forma errática).
var hbClient = &http.Client{
	Timeout:   2 * time.Second,
	Transport: &http.Transport{DisableKeepAlives: true},
}

// O canário tem cliente PRÓPRIO com timeout generoso: ele não é probe de
// vivacidade — leitura lenta ainda é leitura válida do contador. Com o
// timeout curto do health (2s), o canário era estrangulado exatamente na
// janela pós-restore (backend saturado), atrasando a detecção de regressão
// em minutos e abrindo espaço pro snapshot "lavar" o buffer (writes
// perdidos). Medido no v5: detecção foi de 67s pra 269s.
var canaryClient = &http.Client{
	Timeout:   30 * time.Second,
	Transport: &http.Transport{DisableKeepAlives: true},
}

// flushGrace é a janela após um desbloqueio de tráfego pós-snapshot em que
// erros de APLICAÇÃO (status>299) no health não fecham o gate: o backend está
// digerindo o flush de backlog, não morto. Connection refused fecha SEMPRE
// (sinal inequívoco de pod morto, independe de graça).
const flushGrace = 60 * time.Second

func inFlushGrace() bool {
	t := crController.LastTrafficRelease.Load()
	return t > 0 && time.Since(time.Unix(0, t)) < flushGrace
}

// canaryKey é a chave reservada do canário de regressão de estado — fora do
// range usado pelos benchmarks/seeds (que ficam abaixo de ~2M).
const canaryKey = "999999999"

// lastCanary é o último valor que ESTE interceptor escreveu (ou adotou) no
// canário. Se a leitura regredir, o backend foi restaurado de um checkpoint
// antigo e o buffer pós-snapshot precisa de replay.
var lastCanary uint64

func Monitor() {
	// This function should be called in a go routine
	// It should monitor the heartbeat of the interceptor
	// If the interceptor is not responding, it should restart the interceptor
	path := config.GetHeartBeatPath()
	applicationURL := strings.TrimRight(config.GetApplicationURL(), "/")
	fullPath := applicationURL + "/" + path
	// Make a request to the interceptor
	numberRequestsFailed := 0
	numberRequestsSuccess := 0
	consecutiveRefused := 0

	// O canário roda em loop PRÓPRIO: no loop único, um canaryGet lento
	// (até 30s sob flush) atrasava os ticks de health — janelas de outage
	// podiam passar com 1 só refused (gate não fechava) e o veredito do
	// canário ficava preso atrás do health.
	go canaryLoop(applicationURL)

	tick := time.Tick(5 * time.Second)
	for range tick {
		// #E: skip enquanto snapshot/restore esta acontecendo. CRIU congela o backend
		// durante o dump, fazendo /health retornar timeout/erro -- contar como falha
		// abriria o circuito falsamente.
		if crController.IsDoingSnapshot.Load() || crController.IsRestoringSnapshot.Load() {
			numberRequestsFailed = 0
			numberRequestsSuccess = 0
			continue
		}
		resp, err := hbClient.Get(fullPath)
		if err != nil {
			numberRequestsSuccess = 0
			if errors.Is(err, syscall.EADDRNOTAVAIL) {
				// Esgotamento de portas efêmeras LOCAIS (o interceptor é o
				// cliente das conexões upstream): não diz nada sobre o backend
				// — não conta nem como morte nem como saturação dele.
				log.Warn().Msg("Health check failed: local ephemeral port exhaustion")
				continue
			}
			if errors.Is(err, syscall.ECONNREFUSED) {
				// Pod morto de verdade (kube-proxy rejeita sem endpoints).
				// Refused é inequívoco: 2 consecutivos bastam pra fechar o
				// gate (~10s) — esperar 6 deixava a outage inteira desprotegida
				// quando o pod restaurava rápido (medido no v5: gate nem fechou).
				consecutiveRefused++
				if consecutiveRefused >= 2 {
					// Morte confirmada => restore vem aí => regressão de estado
					// é certa: exige veredito do canário antes de reabrir.
					crController.CanaryVerdictPending.Store(true)
					crController.IsContainerUnavailable.Store(true)
				}
			}
			// Timeout/reset/etc: dentro da janela de flush é saturação
			// esperada (fechar amplificaria); fora dela, um streak longo é
			// morte que não conseguimos ver como refused (ex.: porta esgotada
			// mascarando o refused — medido) — fecha o gate.
			if !errors.Is(err, syscall.ECONNREFUSED) && !inFlushGrace() {
				numberRequestsFailed++
				if numberRequestsFailed > 5 {
					crController.CanaryVerdictPending.Store(true)
					crController.IsContainerUnavailable.Store(true)
				}
			}
			continue
		}
		_, _ = io.ReadAll(resp.Body)
		resp.Body.Close()
		consecutiveRefused = 0
		if resp.StatusCode > 299 {
			numberRequestsSuccess = 0
			if !inFlushGrace() {
				// Erro de aplicação fora da janela de flush: conta.
				numberRequestsFailed++
			}
		} else {
			numberRequestsSuccess++
			numberRequestsFailed = 0
		}
		if numberRequestsFailed > 5 {
			crController.CanaryVerdictPending.Store(true)
			crController.IsContainerUnavailable.Store(true)
		}
		if numberRequestsSuccess > 5 && crController.CanaryVerdictPending.Load() {
			// Health saudável mas o canário ainda não deu veredito desde o
			// fechamento: gate continua fechado até o veredito (ordem
			// restore -> veredito -> replay -> tráfego).
			log.Warn().Msg("Gate reopen waiting for canary verdict")
		}
		if numberRequestsSuccess > 5 && !crController.CanaryVerdictPending.Load() {
			// Transição indisponível -> disponível: só libera o tráfego. O
			// replay fica EXCLUSIVAMENTE com o canário: a transição dispara em
			// falso-positivo (flush de backlog derruba o /health sem restore
			// nenhum) e, num restore real, dispara DEPOIS do canário, re-
			// enfileirando o que o replay já re-registrou no buffer —
			// amplificação (medido: 173K do canário + 197K da transição).
			if crController.IsContainerUnavailable.Load() {
				log.Warn().Msg("Recovery detected by heartbeat: unblocking traffic (replay delegated to canary)")
			}
			crController.IsContainerUnavailable.Store(false)
		}

	}
}

// canaryLoop roda o canário de regressão em ritmo próprio, independente do
// health (um canaryGet lento não pode atrasar a detecção de morte). Todo
// restore real regride o contador (monotônico, escrito a cada tick; o
// checkpoint é sempre mais velho); flush/overload não regride => sem
// falso-positivo. Lê MESMO com o gate fechado: o veredito antes da reabertura
// enfileira o replay na frente do tráfego represado.
func canaryLoop(appURL string) {
	tick := time.Tick(5 * time.Second)
	for range tick {
		// kv congelado durante o dump: leitura seria timeout inútil.
		if crController.IsDoingSnapshot.Load() || crController.IsRestoringSnapshot.Load() {
			continue
		}
		checkCanary(appURL)
	}
}

// checkCanary lê o canário no backend e compara com o último valor escrito.
// Regressão (valor menor, ou chave sumida) => o backend foi restaurado de um
// checkpoint anterior => replay do buffer. Depois avança e regrava o canário.
func checkCanary(appURL string) {
	cur, found, err := canaryGet(appURL)
	if err != nil {
		// Instrumentação: leituras falhando em série são exatamente o que
		// atrasa o veredito (e mantém o gate fechado) — precisa ser visível.
		log.Warn().Err(err).Msg("Canary read failed")
		return
	}
	if found {
		if lastCanary == 0 {
			// Interceptor (re)iniciou: adota o valor existente como base.
			lastCanary = cur
		} else if cur < lastCanary {
			stateRegressionRecovery()
		}
	} else if lastCanary > 0 {
		// Canário sumiu: restore pra um checkpoint anterior à sua criação.
		stateRegressionRecovery()
	}
	// Leitura completou: temos um veredito (limpo ou regressão+replay) — o
	// gate pode reabrir e o snapshotter pode voltar a rodar.
	if crController.CanaryVerdictPending.Swap(false) {
		log.Warn().Msg("Canary verdict delivered: gate may reopen")
	}
	lastCanary++
	if err := canaryPost(appURL, lastCanary); err != nil {
		lastCanary-- // não conseguiu gravar: não avança a régua
	}
}

// stateRegressionRecovery bloqueia brevemente a admissão, re-enfileira o buffer
// pós-snapshot e libera — os replays drenam antes das requests novas.
func stateRegressionRecovery() {
	log.Warn().Uint64("last_canary", lastCanary).
		Msg("State regression detected (canary rolled back): backend restored from older checkpoint")
	crController.IsContainerUnavailable.Store(true)
	n := crController.ReplayBufferedRequests()
	crController.IsContainerUnavailable.Store(false)
	log.Warn().Int("replayed", n).Msg("State regression recovery: buffered requests queued for replay")
}

func canaryGet(appURL string) (uint64, bool, error) {
	resp, err := canaryClient.Get(appURL + "/?key=" + canaryKey)
	if err != nil {
		return 0, false, err
	}
	defer resp.Body.Close()
	body, readErr := io.ReadAll(resp.Body)
	if readErr != nil {
		return 0, false, readErr
	}
	if resp.StatusCode == http.StatusNotFound {
		return 0, false, nil
	}
	if resp.StatusCode != http.StatusOK {
		return 0, false, errBadStatus
	}
	v := strings.Trim(strings.TrimSpace(string(body)), "\"")
	n, parseErr := strconv.ParseUint(v, 10, 64)
	if parseErr != nil {
		// Valor ilegível: não dá pra raciocinar sobre regressão neste tick.
		return 0, false, parseErr
	}
	return n, true, nil
}

var errBadStatus = errBadStatusType{}

type errBadStatusType struct{}

func (errBadStatusType) Error() string { return "canary get: unexpected status" }

func canaryPost(appURL string, val uint64) error {
	form := url.Values{"key": {canaryKey}, "value": {strconv.FormatUint(val, 10)}}
	resp, err := canaryClient.PostForm(appURL+"/", form)
	if err != nil {
		return err
	}
	_, _ = io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode > 299 {
		return errBadStatus
	}
	return nil
}
