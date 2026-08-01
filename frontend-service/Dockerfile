FROM node:20
WORKDIR /app
# Run as non-root for security (Trivy DS-0002 / Hadolint DL3002)
RUN groupadd --system appgroup && useradd --system --gid appgroup --no-create-home --shell /bin/bash appuser

COPY package*.json ./
RUN npm ci
COPY . .
RUN chown -R appuser:appgroup /app
USER appuser

ARG REACT_APP_API_BASE_URL=/api
ENV REACT_APP_API_BASE_URL=$REACT_APP_API_BASE_URL
ENV NODE_OPTIONS="--max-old-space-size=2048"
ENV CI=false

EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD curl -sf http://localhost:3000 || exit 1
CMD ["npm", "start"]
