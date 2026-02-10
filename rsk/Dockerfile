FROM eclipse-temurin:17-jdk@sha256:0613a19436dc8f745914b25235d43f3b0eddb8d432d19edce30ffaf2d2f95403 AS build

RUN apt-get update -y && \
  apt-get install -y git curl gnupg

RUN useradd -ms /bin/bash rsk
USER rsk

WORKDIR /home/rsk
COPY --chown=rsk:rsk repos/rskj ./

RUN curl -sL https://secchannel.rsk.co/SUPPORT.asc | gpg --import && \
  gpg --verify --output SHA256SUMS SHA256SUMS.asc && \
  sha256sum --check SHA256SUMS && \
  ./configure.sh && \
  ./gradlew --no-daemon clean build -x test && \
  file=rskj-core/src/main/resources/version.properties && \
  version_number=$(sed -n 's/^versionNumber=//p' "$file" | tr -d "\"'") && \
  modifier=$(sed -n 's/^modifier=//p' "$file" | tr -d "\"'") && \
  cp "rskj-core/build/libs/rskj-core-$version_number-$modifier-all.jar" rsk.jar

FROM eclipse-temurin:17-jre@sha256:38e0afc86a10bf4cadbf1586fb617b3a9a4d09c9a0be882e29ada4ed0895fc84
LABEL org.opencontainers.image.authors="ops@rootstocklabs.com"

RUN useradd -ms /sbin/nologin -d /var/lib/rsk rsk

# Use a separate directory for JMX to avoid volume mount overrides
RUN mkdir -p /usr/local/lib/rsk && chown rsk:rsk /usr/local/lib/rsk

USER rsk
WORKDIR /var/lib/rsk
COPY --from=build --chown=rsk:rsk /home/rsk/rsk.jar ./
COPY --from=build --chown=rsk:rsk /home/rsk/test/node-timedMine.conf /var/lib/rsk/test/node-timedMine.conf

WORKDIR /usr/local/lib/rsk
COPY --chown=rsk:rsk rsk/jmx_prometheus_javaagent.jar ./
COPY --chown=rsk:rsk rsk/jmx_exporter_config.yaml ./

WORKDIR /var/lib/rsk

ENV ENABLE_JMX="false"
ENV JMX_PORT="9010"
ENV JMX_HOSTNAME="127.0.0.1"

ENV MINER_ID="1"
ENV IS_MINER="true"
ENV WIRE_DELAY="100"
ENV DEFAULT_JVM_OPTS="-Xms3G"
ENV RSKJ_SYS_PROPS="-Drsk.conf.file=./test/node-timedMine.conf -DtxLoad.profile=cpu -DtxLoad.enabled=false -Drsk.conf.file=./test/node-timedMine.conf -Drpc.providers.web.cors=* -Drpc.providers.web.http.port=4444 -Drpc.providers.web.http.enabled=true -Drpc.providers.web.ws.enabled=true -Drpc.providers.web.ws.port=4445 -Ddatabase.dir=./test/local-regtest/database -Dtransaction.accountTxRateLimit.enabled=false -Dlogging.dir=test/local-regtest/ -Dsync.peer.count=20 -Drpc.providers.web.http.bind_address=0.0.0.0 -Drpc.providers.web.http.hosts.0=localhost -Drpc.providers.web.http.hosts.1=127.0.0.1 -Drpc.providers.web.http.hosts.2=::1"
ENV RSKJ_LOG_PROPS="-Dlogging.stdout=TRACE -Dlogging.file=TRACE -Dlogging=TRACE" 
ENV RSKJ_CLASS=co.rsk.Start
ENV RSKJ_OPTS="--regtest"
ENV BLOCK_GAS_LIMIT="7000000"
ENV GENESIS_FILE=""


ENTRYPOINT ["/bin/sh", "-c", "\
  JMX_OPTS=''; \
  if [ \"${ENABLE_JMX}\" = \"true\" ]; then \
  JMX_OPTS=\"-Dcom.sun.management.jmxremote \
  -Dcom.sun.management.jmxremote.port=${JMX_PORT} \
  -Dcom.sun.management.jmxremote.rmi.port=${JMX_PORT} \
  -Dcom.sun.management.jmxremote.local.only=false \
  -Dcom.sun.management.jmxremote.authenticate=false \
  -Dcom.sun.management.jmxremote.ssl=false \
  -Djava.rmi.server.hostname=${JMX_HOSTNAME}\"; \
  fi; \
  MINER_OPTS=''; \
  if [ \"${IS_MINER}\" = \"true\" ]; then \
  MINER_OPTS=\"-Dminer.server.enabled=true \
  -Dminer.client.timedMine=true \
  -Dminer.coinbase.secret=miner${MINER_ID} \
  -Dpeer.privateKey=AFF6A83FEFFF6FF0C9F6FFFE41F6FF10D9FFFF3F41FFCFBF41F6FF90DFFFFF9${MINER_ID} \
  -Dpeer.port=5050${MINER_ID} \
  -Dminer.client.medianBlockTime=16s\"; \
  else \
  MINER_OPTS=\"-Dminer.server.enabled=false \
  -Dpeer.privateKey=AFF6A83FEFFF6FF0C9F6FFFE41F6FF10D9FFFF3F41FFCFBF41F6FF90DFFFFF8${MINER_ID} \
  -Dpeer.port=5060${MINER_ID} \
  -Dminer.client.timedMine=false\"; \
  fi; \
  GENESIS_OPT=''; \
  if [ -n \"${GENESIS_FILE}\" ]; then \
  GENESIS_OPT=\"-Dgenesis=${GENESIS_FILE}\"; \
  fi; \
  exec java $DEFAULT_JVM_OPTS \
  -javaagent:/usr/local/lib/rsk/jmx_prometheus_javaagent.jar=8080:/usr/local/lib/rsk/jmx_exporter_config.yaml \
  $RSKJ_SYS_PROPS \
  $MINER_OPTS \
  -Dminer.server.skipPowValidation=true \
  -Drpc.providers.web.http.hosts.3=rskj-miner${MINER_ID} \
  -Drpc.providers.web.http.hosts.4=rskj-node${MINER_ID} \
  -Dwire.simulatedDelay=${WIRE_DELAY} \
  -DtxLoad.blockTargetGas=${BLOCK_GAS_LIMIT} \
  -DtxLoad.primaryTxGas=${BLOCK_GAS_LIMIT} \
  -Drpc.gasEstimationCap=${BLOCK_GAS_LIMIT} \
  -Dtargetgaslimit=${BLOCK_GAS_LIMIT} \
  -Dsystem.profiling.enabled=true \
  -Dblockchain.flushNumberOfBlocks=${FLUSH_BLOCKS} \
  $GENESIS_OPT \
  $JMX_OPTS \
  $RSKJ_LOG_PROPS \
  -cp rsk.jar $RSKJ_CLASS $RSKJ_OPTS \"${@}\" \
  ", "--"]

