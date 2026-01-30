FROM node:9-alpine AS builder
RUN apk add --no-cache build-base git python3
USER node
WORKDIR /home/node
COPY --chown=node:node package*.json ./
RUN npm i
FROM node:9-alpine
USER node
WORKDIR /home/node
COPY --chown=node:node . ./
COPY --from=builder /home/node/node_modules ./node_modules
CMD ["node", "app.js"]