FROM node:22-alpine

WORKDIR /app
ENV NODE_ENV=production

COPY package.json package-lock.json ./
RUN npm ci --omit=dev

COPY src ./src

RUN mkdir -p /data && chown -R node:node /app /data
USER node

ENV PORT=8787
ENV DATA_FILE=/data/database.json
EXPOSE 8787

CMD ["node", "src/server.js"]
