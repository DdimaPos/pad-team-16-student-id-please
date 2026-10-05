# Gateway Service - Integration Reference

> **Status:** skeleton. Lab 2, issue #39. Python gateway, single entry point of the system.
> Sections marked _TBD_ are filled in by the PRs that implement them.

## 1. What this service is

The Gateway is the one public entry point: clients and services reach every other service through it.
It owns no data and publishes no events.

## 2. Integration card

|                          |                                                                                                        |
| ------------------------ | ------------------------------------------------------------------------------------------------------ |
| **Language / framework** | Python 3.12, FastAPI, httpx                                                                            |
| **Container port**       | `8080` (host `8080`)                                                                                   |
| **Health**               | `GET /health`                                                                                          |
| **Error envelope**       | `{ "error": { "code", "message", "details" } }`, same as every service                                 |
| **Docker image**         | `d1vinexd/gateway-service:<lab version>` and `:latest`, published by GitHub Actions on merge to `main` |

## 3. Running it

_TBD_ - see the service repository README.

## 4. Configuration

_TBD_ - route table, peer URLs, `JWT_SECRET`, `SERVICE_TOKEN`, timeout and concurrency variables.

## 5. Routing

_TBD_ (issue #40, section 1).

## 6. Authorization

_TBD_ (issue #40, section 2): `Authorization` is validated here and not forwarded downstream.

## 7. Limits and error codes

_TBD_ (issue #40, section 3).

## 8. WebSocket negotiation

_TBD_ (issue #40, section 4).
