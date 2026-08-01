# Moved

This folder was split to match the application repos:

| Path | Owns |
| --- | --- |
| [`../stayledger-ai-assistant-api/`](../stayledger-ai-assistant-api/) | API, workers, datastores, Alembic jobs, observability |
| [`../stayledger-ai-assistant-admin-web/`](../stayledger-ai-assistant-admin-web/) | Next.js admin UI |

Namespace remains `stayledger-ai-assistant`. Docker images are unchanged (`putin111/ai-hotel-assistant`, `putin111/ai-hotel-assistant-frontend`).

Update Argo CD Applications from `argocd/` under each new folder (project stays `stayledger-ai-assistant` in the API tree).
