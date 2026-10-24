# ymcq dev app env: env template rendered by the secrets-render login agent
# (modules/darwin.nix) into the rendered env file ymcq dev loads.
# References only, by opaque vault, item and section IDs: vault = agent vault,
# item = the ymcq dev app env item (a copy of the item in the project vault).
# Variable names equal ~/Dev/ymcq/.env.tpl; the plain lines are local dev
# settings, not secrets.
# Keep plain values unquoted: secrets-render counts quoted lines as
# rendered references.

# Core
NODE_ENV=development
DATABASE_URL=op://2qhxakza24vgbrdzpqqoo6gl6q/kvyopqo4na7ycl3tkj6ksfkj5m/Section_qylq2h7ttjuzbwzt52gkh6ance/DATABASE_URL

# Auth / sessions
AUTH_SECRET=op://2qhxakza24vgbrdzpqqoo6gl6q/kvyopqo4na7ycl3tkj6ksfkj5m/Section_qylq2h7ttjuzbwzt52gkh6ance/AUTH_SECRET
AUTH_URL=https://web.ymcq.localhost
SESSION_COOKIE_NAME=ymcq_session
CORS_ALLOWLIST=https://web.ymcq.localhost,https://landing.ymcq.localhost,http://localhost:3000,http://localhost:3001,http://localhost:3333,http://localhost:4000,http://localhost:4001

# Backend/API
PORT=4000

# Polar billing (optional — checkout returns a friendly error when unset)
POLAR_API_KEY=op://2qhxakza24vgbrdzpqqoo6gl6q/kvyopqo4na7ycl3tkj6ksfkj5m/Section_qylq2h7ttjuzbwzt52gkh6ance/POLAR_API_KEY
POLAR_WEBHOOK_SECRET=op://2qhxakza24vgbrdzpqqoo6gl6q/kvyopqo4na7ycl3tkj6ksfkj5m/Section_qylq2h7ttjuzbwzt52gkh6ance/POLAR_WEBHOOK_SECRET
POLAR_ENVIRONMENT=sandbox
NEXT_PUBLIC_POLAR_CLIENT_ID=op://2qhxakza24vgbrdzpqqoo6gl6q/kvyopqo4na7ycl3tkj6ksfkj5m/Section_qylq2h7ttjuzbwzt52gkh6ance/NEXT_PUBLIC_POLAR_CLIENT_ID

# Storage (R2/S3-compatible)
R2_ACCESS_KEY_ID=op://2qhxakza24vgbrdzpqqoo6gl6q/kvyopqo4na7ycl3tkj6ksfkj5m/Section_qylq2h7ttjuzbwzt52gkh6ance/R2_ACCESS_KEY_ID
R2_SECRET_ACCESS_KEY=op://2qhxakza24vgbrdzpqqoo6gl6q/kvyopqo4na7ycl3tkj6ksfkj5m/Section_qylq2h7ttjuzbwzt52gkh6ance/R2_SECRET_ACCESS_KEY
R2_ACCOUNT_ID=op://2qhxakza24vgbrdzpqqoo6gl6q/kvyopqo4na7ycl3tkj6ksfkj5m/Section_qylq2h7ttjuzbwzt52gkh6ance/R2_ACCOUNT_ID
R2_BUCKET=ymcq-uploads
# R2_ENDPOINT is a reference: it holds the R2 account ID (owner decision on #5).
R2_ENDPOINT=op://2qhxakza24vgbrdzpqqoo6gl6q/kvyopqo4na7ycl3tkj6ksfkj5m/Section_qylq2h7ttjuzbwzt52gkh6ance/R2_ENDPOINT

# Web
NEXT_PUBLIC_APP_URL=http://localhost:3001
NEXT_PUBLIC_API_BASE_URL=http://localhost:4000

# CMS (Payload)
PAYLOAD_SECRET=op://2qhxakza24vgbrdzpqqoo6gl6q/kvyopqo4na7ycl3tkj6ksfkj5m/Section_qylq2h7ttjuzbwzt52gkh6ance/PAYLOAD_SECRET
PAYLOAD_PUBLIC_SERVER_URL=http://localhost:4001
PAYLOAD_URL=http://localhost:4001

# Redis
REDIS_HOST=localhost
REDIS_PORT=6380
REDIS_URL=op://2qhxakza24vgbrdzpqqoo6gl6q/kvyopqo4na7ycl3tkj6ksfkj5m/Section_qylq2h7ttjuzbwzt52gkh6ance/REDIS_URL

# Admin API key shared between web and cms
ADMIN_API_KEY=op://2qhxakza24vgbrdzpqqoo6gl6q/kvyopqo4na7ycl3tkj6ksfkj5m/Section_qylq2h7ttjuzbwzt52gkh6ance/ADMIN_API_KEY

# Email (Resend)
RESEND_API_KEY=op://2qhxakza24vgbrdzpqqoo6gl6q/kvyopqo4na7ycl3tkj6ksfkj5m/Section_qylq2h7ttjuzbwzt52gkh6ance/RESEND_API_KEY
