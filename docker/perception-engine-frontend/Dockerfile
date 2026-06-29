FROM node:25.5-alpine AS build

WORKDIR /app

COPY package*.json .npmrc ./
RUN npm install

COPY . .
RUN npm run build

RUN find /app/dist -type f -exec chmod 644 {} \; && \
    find /app/dist -type d -exec chmod 755 {} \;

# trivy:ignore:DS-0002 -- nginx master process requires root to bind port 80;
# worker processes run as the unprivileged nginx user automatically.
FROM nginx:alpine

COPY --from=build /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf

RUN find /usr/share/nginx/html -type f -exec chmod 644 {} \; && \
    find /usr/share/nginx/html -type d -exec chmod 755 {} \;

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
