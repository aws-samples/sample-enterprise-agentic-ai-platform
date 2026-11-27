# EAP ADE Invoke Backend (ADR-040)
# Always-on streaming invoke backend for the Agent Deployment Engineer console
# chat. Runs on ECS Fargate behind an INTERNAL ALB. In demo it is fronted by the
# console CloudFront (/ade-api/*); in enterprise the ALB is internal-only and
# reached by the customer's BYO UI.
#
# Streams A2A message/stream deltas as SSE, and enforces Cognito/OIDC JWT auth +
# the Requirement-11 runtime allow-list (parity with the invoke-proxy Lambda).
FROM public.ecr.aws/docker/library/node:20-slim

WORKDIR /app

# Install runtime deps first for layer caching. tsx is a runtime dependency
# (the service runs TypeScript directly — no build step).
COPY package.json ./
RUN npm install --omit=dev --no-audit --no-fund

# App sources.
COPY tsconfig.json ./
COPY server.ts ./
COPY src ./src

ENV NODE_ENV=production
ENV PORT=8080
EXPOSE 8080

CMD ["npx", "tsx", "server.ts"]
