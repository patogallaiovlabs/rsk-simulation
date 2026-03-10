FROM node:16-slim

WORKDIR /app

COPY package*.json ./
RUN npm install --production

COPY exporter.js ./

EXPOSE 9090

CMD ["node", "exporter.js"]
