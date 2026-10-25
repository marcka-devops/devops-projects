FROM node:20-alpine

# Build client
WORKDIR /usr/src/app/client
COPY client/package*.json ./
RUN npm install
COPY client/ ./
RUN npm run build

# Install server in its own directory (do not reuse client WORKDIR)
WORKDIR /usr/src/app/server
COPY server/package*.json ./
RUN npm install --omit=dev
COPY server/ ./

RUN mkdir -p ./public && cp -R /usr/src/app/client/public/* ./public/

ENV NODE_ENV=production

RUN addgroup -S appgroup && adduser -S appuser -G appgroup \
  && chown -R appuser:appgroup /usr/src/app

USER appuser

EXPOSE 5000

CMD ["npm", "start"]
