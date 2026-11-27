# EAP Studio-Read Backend
# Always-on ECS/Fargate service serving the Console Build workspace read-only
# routes. Runs behind an ALB (internal in enterprise; CloudFront-fronted /api/*
# in demo). Self-validates the Cognito/OIDC JWT (no API Gateway authorizer) —
# same pattern as the ADE invoke backend (ADR-040). No streaming: buffered JSON.
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
