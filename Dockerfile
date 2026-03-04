# ─────────────────────────────────────────────────────────────
# Brain Tasks App — Dockerfile
#
# Base: nginx:alpine (~25MB)
# No build stage needed — repo ships pre-compiled dist/ output.
# nginx serves static files and handles SPA client-side routing.
# ─────────────────────────────────────────────────────────────

FROM nginx:1.25-alpine

# Remove default nginx static content
RUN rm -rf /usr/share/nginx/html/*

# Copy pre-built React app from dist/ into nginx web root
COPY dist/ /usr/share/nginx/html/

# Copy custom nginx config
# Required for React Router — without this, any route except /
# returns 404 because nginx looks for a real file at that path.
COPY nginx.conf /etc/nginx/conf.d/default.conf

# Expose port 80 (nginx default)
# NOTE: Kubernetes service maps external 3000 → container 80
EXPOSE 80

# nginx starts automatically — no CMD override needed
