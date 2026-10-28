FROM node:22-alpine AS deps

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund

FROM node:22-alpine AS runtime

LABEL org.opencontainers.image.title="mern-crash-course-backend"
LABEL org.opencontainers.image.description="Express API for the MERN crash course"

ENV NODE_ENV=production
ENV NODE_OPTIONS=--max-old-space-size=256

WORKDIR /app

COPY --from=deps --chown=node:node /app/node_modules ./node_modules
COPY --chown=node:node package.json ./
COPY --chown=node:node backend ./backend

USER node

EXPOSE 5000

HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=5 \
	CMD wget -qO- http://127.0.0.1:5000/api/health >/dev/null || exit 1

CMD ["node", "backend/server.js"]
