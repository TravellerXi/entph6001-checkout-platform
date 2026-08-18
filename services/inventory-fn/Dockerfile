FROM node:lts-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm ci --omit=dev || npm install --omit=dev

FROM node:lts-alpine
# The bundled npm CLI drags in tar/undici/ip-address/brace-expansion, reported by Trivy as
# HIGH/CRITICAL. None are reachable from the running service and a production image needs no
# package manager, so the whole class of findings is removed rather than suppressed.
RUN rm -rf /usr/local/lib/node_modules/npm /usr/local/bin/npm /usr/local/bin/npx
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY app.js obs.js package.json ./
USER node
EXPOSE 3002
CMD ["node", "app.js"]