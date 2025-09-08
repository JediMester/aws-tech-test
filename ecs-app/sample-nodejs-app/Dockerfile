# Dockerfile (multi-arch friendly, ARM64-ready)
FROM node:20-alpine

# Biztonságosabb default user
# USER node

WORKDIR /app

# Csak a deps fájlokat másoljuk először a cache miatt
COPY package.json yarn.lock ./

# Csak a lock + package fájlokat másoljuk először a cache miatt
# COPY --chown=node:node package.json yarn.lock ./

# Yarn bekapcsolása és prod dep-ek telepítése
# (ha classic Yarn lockfile van, a --frozen-lockfile jó választás)
RUN corepack enable \
 && corepack prepare yarn@1.22.22 --activate \
 && yarn install --frozen-lockfile --production=true

# App forrás bemásolása
# COPY --chown=node:node . .
COPY . .

# Node modules tulajdon váltás a nem-root futtatáshoz
RUN chown -R node:node /app

# MOST váltunk nem-root userre
USER node

# Prod környezet + port
ENV NODE_ENV=production
ENV PORT=8080

EXPOSE 8080

# Ha a package.json-ban van "start" script, ez működik:
CMD ["yarn", "start"]

