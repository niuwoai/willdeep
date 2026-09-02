package agent

import (
	"context"
	"encoding/json"
	"log"

	larkevent "github.com/larksuite/oapi-sdk-go/v3/event"
	"github.com/larksuite/oapi-sdk-go/v3/event/dispatcher"
	larkws "github.com/larksuite/oapi-sdk-go/v3/ws"
)

type feishuLongConnectionClient interface {
	Start(ctx context.Context) error
	Close()
}

type feishuLongConnectionClientFactory func(config CollaborationRelayConfig, eventHandler *dispatcher.EventDispatcher, callbacks feishuLongConnectionCallbacks) feishuLongConnectionClient

type feishuLongConnectionCallbacks struct {
	OnReady        func()
	OnError        func(error)
	OnReconnecting func()
	OnReconnected  func()
	OnDisconnected func()
}

var newFeishuLongConnectionClient feishuLongConnectionClientFactory = func(config CollaborationRelayConfig, eventHandler *dispatcher.EventDispatcher, callbacks feishuLongConnectionCallbacks) feishuLongConnectionClient {
	return larkws.NewClient(
		config.FeishuAppID,
		config.FeishuAppSecret,
		larkws.WithEventHandler(eventHandler),
		larkws.WithSource("willdeep-agent/"+Version),
		larkws.WithOnReady(callbacks.OnReady),
		larkws.WithOnError(callbacks.OnError),
		larkws.WithOnReconnecting(callbacks.OnReconnecting),
		larkws.WithOnReconnected(callbacks.OnReconnected),
		larkws.WithOnDisconnected(callbacks.OnDisconnected),
	)
}

func (r *CollaborationRelay) StartBackgroundTransports(ctx context.Context) error {
	if !r.config.FeishuLongConnectionEnabled {
		return nil
	}
	return r.startFeishuLongConnection(ctx)
}

func (r *CollaborationRelay) startFeishuLongConnection(ctx context.Context) error {
	r.setFeishuLongConnectionStatus("starting", "")
	eventHandler := dispatcher.NewEventDispatcher("", "")
	for _, eventType := range r.config.FeishuLongConnectionEventTypes {
		eventType := eventType
		eventHandler.OnCustomizedEvent(eventType, func(ctx context.Context, event *larkevent.EventReq) error {
			return r.handleFeishuLongConnectionEvent(ctx, eventType, event)
		})
	}

	client := newFeishuLongConnectionClient(r.config, eventHandler, feishuLongConnectionCallbacks{
		OnReady: func() {
			r.setFeishuLongConnectionStatus("connected", "")
		},
		OnError: func(err error) {
			r.setFeishuLongConnectionStatus("error", err.Error())
		},
		OnReconnecting: func() {
			r.setFeishuLongConnectionStatus("reconnecting", "")
		},
		OnReconnected: func() {
			r.setFeishuLongConnectionStatus("connected", "")
		},
		OnDisconnected: func() {
			r.setFeishuLongConnectionStatus("disconnected", "")
		},
	})

	go func() {
		err := client.Start(ctx)
		if err != nil {
			r.setFeishuLongConnectionStatus("error", err.Error())
			log.Printf("willdeep-agent feishu long connection stopped: %v", err)
		}
	}()
	go func() {
		<-ctx.Done()
		client.Close()
	}()
	return nil
}

func (r *CollaborationRelay) handleFeishuLongConnectionEvent(ctx context.Context, eventType string, event *larkevent.EventReq) error {
	body := append([]byte(nil), event.Body...)
	var envelope map[string]any
	if err := json.Unmarshal(body, &envelope); err != nil {
		return err
	}
	headers := map[string]any{
		"X-WillDeep-Event-Transport": "feishu-long-connection",
		"X-WillDeep-Feishu-Event":    eventType,
	}
	for key, values := range event.Header {
		if len(values) == 1 {
			headers[key] = values[0]
			continue
		}
		if len(values) > 1 {
			headers[key] = append([]string(nil), values...)
		}
	}
	kind := relayEventKind(envelope)
	if kind == "event" {
		kind = eventType
	}
	now := r.now()
	_, err := r.enqueue(CollaborationRelayEvent{
		ID:                   relayEventID("feishu", envelope, now),
		Platform:             "feishu",
		Kind:                 kind,
		ReceivedAt:           now.UTC(),
		RemoteAddr:           "feishu-long-connection",
		Headers:              headers,
		Body:                 json.RawMessage(body),
		AuthenticatedIngress: true,
	})
	if err != nil {
		return err
	}
	_ = ctx
	return nil
}
