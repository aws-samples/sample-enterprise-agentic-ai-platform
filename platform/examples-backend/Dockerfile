# EAP Examples Backend (ADR-037)
# Single generic signer service for the demo console Examples surface.
# Runs on ECS Fargate behind an ALB (private; reached only via CloudFront).
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
