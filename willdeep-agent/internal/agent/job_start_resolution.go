package agent

import (
	"errors"
	"net/http"
)

func startRequestErrorStatus(err error) int {
	switch {
	case errors.Is(err, ErrRunDeadlineExpired):
		return http.StatusGone
	case errors.Is(err, ErrRunDeadlineInvalid):
		return http.StatusBadRequest
	case errors.Is(err, ErrStartInstanceChanged):
		return http.StatusPreconditionFailed
	case errors.Is(err, ErrStartKeyInvalid):
		return http.StatusBadRequest
	case errors.Is(err, ErrStartKeyConflict), errors.Is(err, ErrStartKeySealed):
		return http.StatusConflict
	case errors.Is(err, ErrStartKeyCapacity):
		return http.StatusServiceUnavailable
	default:
		return http.StatusInternalServerError
	}
}

func (s *Server) handleRunStartReconcile(w http.ResponseWriter, r *http.Request) {
	var request struct {
		ExpectedInstanceID string `json:"expected_instance_id"`
	}
	if err := decodeJSON(r.Body, &request); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	result, err := s.jobs.ReconcileStart(request.ExpectedInstanceID, r.PathValue("key"))
	if err != nil {
		writeError(w, startRequestErrorStatus(err), err.Error())
		return
	}
	writeOK(w, result)
}
