FROM mcr.microsoft.com/playwright:v1.61.1-noble@sha256:5b8f294aff9041b7191c34a4bab3ac270157a28774d4b0660e9743297b697e48

WORKDIR /work
RUN npm install --no-save --save-exact playwright@1.61.1

COPY tests/ui-smoke.cjs /work/tests/ui-smoke.cjs
COPY tests/world-map-smoke.cjs /work/tests/world-map-smoke.cjs
COPY tests/resource-console-smoke.cjs /work/tests/resource-console-smoke.cjs
COPY tests/information-layer-console-smoke.cjs /work/tests/information-layer-console-smoke.cjs
COPY tests/performance-smoke.cjs /work/tests/performance-smoke.cjs
COPY tests/performance-baseline.json /work/tests/performance-baseline.json

ENV TERRASYS_UI_URL=http://terrasys-web
CMD ["node", "/work/tests/ui-smoke.cjs"]
