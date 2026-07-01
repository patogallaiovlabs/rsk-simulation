FROM node:20-slim

WORKDIR /app

RUN apt-get update && apt-get install -y docker.io curl && rm -rf /var/lib/apt/lists/*

COPY package*.json ./
RUN npm install --production

COPY exporter.js ./

EXPOSE 9090

CMD ["node", "exporter.js"]
