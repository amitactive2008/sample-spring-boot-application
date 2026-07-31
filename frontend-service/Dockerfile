FROM node:20
WORKDIR /app

COPY package*.json ./
RUN npm ci
COPY . .

ARG REACT_APP_API_BASE_URL=/api
ENV REACT_APP_API_BASE_URL=$REACT_APP_API_BASE_URL
ENV NODE_OPTIONS="--max-old-space-size=2048"

ENV CI=false

EXPOSE 3000
CMD ["npm", "start"]
