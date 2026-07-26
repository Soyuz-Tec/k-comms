#!/usr/bin/env node

import { createHash, randomBytes } from "node:crypto";
import { createSocket } from "node:dgram";
import {
  link,
  lstat,
  mkdir,
  readFile,
  unlink,
  writeFile
} from "node:fs/promises";
import { createConnection, createServer } from "node:net";
import { dirname, isAbsolute, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { TextDecoder } from "node:util";

const LOOPBACK_TARGET = "127.0.0.1";
const LEGACY_CONFIG_SCHEMA_VERSION = 1;
const PROFILED_CONFIG_SCHEMA_VERSION = 2;
const MEDIA_ONLY_PROFILE = "media-only";
const READY_EVENT = "lan_release_forwarder_ready";
const FATAL_EVENT = "lan_release_forwarder_fatal";
const STOPPED_EVENT = "lan_release_forwarder_stopped";
const MAX_UDP_DATAGRAM_BYTES = 65_507;
const MAX_UDP_PENDING_BYTES_GLOBAL = 8 * 1_024 * 1_024;
const PROCESS_START_TIME_UTC = new Date(
  Date.now() - (process.uptime() * 1_000)
).toISOString();

export const DEFAULT_RELEASE_PORTS = Object.freeze({
  app: 4188,
  minio: 5900,
  livekitSignal: 7980,
  livekitTcp: 7981,
  livekitUdp: 7982
});

export const DEFAULT_FORWARDER_LIMITS = Object.freeze({
  maxTcpConnections: 256,
  tcpConnectTimeoutMs: 5_000,
  tcpIdleTimeoutMs: 120_000,
  tcpShutdownGraceMs: 3_000,
  tcpBacklog: 128,
  socketHighWaterMarkBytes: 65_536,
  maxUdpMappings: 256,
  udpMappingIdleTimeoutMs: 60_000,
  maxUdpPendingDatagramsPerMapping: 32,
  maxUdpPendingPublicDatagrams: 1_024
});

const LEGACY_EXPECTED_LISTENERS = Object.freeze([
  Object.freeze({ name: "app", protocol: "tcp" }),
  Object.freeze({ name: "minio", protocol: "tcp" }),
  Object.freeze({ name: "livekitSignal", protocol: "tcp" }),
  Object.freeze({ name: "livekitTcp", protocol: "tcp" }),
  Object.freeze({ name: "livekitUdp", protocol: "udp" })
]);

const MEDIA_ONLY_EXPECTED_LISTENERS = Object.freeze([
  Object.freeze({ name: "livekitTcp", protocol: "tcp" }),
  Object.freeze({ name: "livekitUdp", protocol: "udp" })
]);

const LIMIT_RANGES = Object.freeze({
  maxTcpConnections: Object.freeze([1, 4_096]),
  tcpConnectTimeoutMs: Object.freeze([250, 30_000]),
  tcpIdleTimeoutMs: Object.freeze([1_000, 1_800_000]),
  tcpShutdownGraceMs: Object.freeze([100, 30_000]),
  tcpBacklog: Object.freeze([1, 1_024]),
  socketHighWaterMarkBytes: Object.freeze([4_096, 1_048_576]),
  maxUdpMappings: Object.freeze([1, 4_096]),
  udpMappingIdleTimeoutMs: Object.freeze([1_000, 600_000]),
  maxUdpPendingDatagramsPerMapping: Object.freeze([1, 256]),
  maxUdpPendingPublicDatagrams: Object.freeze([1, 8_192])
});

export class LanReleaseForwarderError extends Error {
  constructor(code, message, options = undefined) {
    super(message, options);
    this.name = "LanReleaseForwarderError";
    this.code = code;
  }
}

function fail(code, message, options = undefined) {
  throw new LanReleaseForwarderError(code, message, options);
}

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function assertExactKeys(value, keys, path) {
  if (!isRecord(value)) {
    fail("CONFIG_INVALID", `${path} must be an object`);
  }

  const expected = [...keys].sort();
  const actual = Object.keys(value).sort();
  if (
    expected.length !== actual.length ||
    expected.some((key, index) => key !== actual[index])
  ) {
    fail(
      "CONFIG_INVALID",
      `${path} must contain exactly: ${expected.join(", ")}`
    );
  }
}

function assertBoundedInteger(value, minimum, maximum, path) {
  if (
    !Number.isSafeInteger(value) ||
    value < minimum ||
    value > maximum
  ) {
    fail(
      "CONFIG_INVALID",
      `${path} must be an integer from ${minimum} through ${maximum}`
    );
  }
  return value;
}

/**
 * A release bind address is deliberately narrower than merely "valid IPv4".
 * It must be canonical dotted-decimal RFC1918 space. Whether an address is a
 * usable host is determined authoritatively by its assignment to a local
 * interface and by the OS bind; suffix heuristics are wrong for non-/24 LANs.
 */
export function isCanonicalRfc1918Host(value) {
  if (typeof value !== "string") {
    return false;
  }

  const match = /^(0|[1-9]\d{0,2})\.(0|[1-9]\d{0,2})\.(0|[1-9]\d{0,2})\.(0|[1-9]\d{0,2})$/.exec(
    value
  );
  if (!match) {
    return false;
  }

  const octets = match.slice(1).map(Number);
  if (octets.some((octet) => octet < 0 || octet > 255)) {
    return false;
  }
  if (octets.join(".") !== value) {
    return false;
  }

  const [first, second] = octets;
  const isPrivate =
    first === 10 ||
    (first === 172 && second >= 16 && second <= 31) ||
    (first === 192 && second === 168);
  return isPrivate;
}

function validateReadinessToken(value) {
  if (
    typeof value !== "string" ||
    value.length < 16 ||
    value.length > 512 ||
    !/^[\x21-\x7e]+$/.test(value)
  ) {
    fail(
      "CONFIG_INVALID",
      "readinessToken must be 16-512 visible ASCII characters"
    );
  }
  return value;
}

function validateListener(value, expected, index) {
  const path = `listeners[${index}]`;
  assertExactKeys(
    value,
    ["name", "protocol", "publicPort", "targetHost", "targetPort"],
    path
  );

  if (value.name !== expected.name) {
    fail("CONFIG_INVALID", `${path}.name must be ${expected.name}`);
  }
  if (value.protocol !== expected.protocol) {
    fail(
      "CONFIG_INVALID",
      `${path}.protocol must be ${expected.protocol}`
    );
  }
  if (value.targetHost !== LOOPBACK_TARGET) {
    fail(
      "CONFIG_INVALID",
      `${path}.targetHost must be exactly ${LOOPBACK_TARGET}`
    );
  }

  const publicPort = assertBoundedInteger(
    value.publicPort,
    1_024,
    65_535,
    `${path}.publicPort`
  );
  const targetPort = assertBoundedInteger(
    value.targetPort,
    1_024,
    65_535,
    `${path}.targetPort`
  );
  if (publicPort !== targetPort) {
    fail(
      "CONFIG_INVALID",
      `${path} must use an exact public-to-loopback port mapping`
    );
  }

  return Object.freeze({
    name: expected.name,
    protocol: expected.protocol,
    publicPort,
    targetHost: LOOPBACK_TARGET,
    targetPort
  });
}

function validateLimits(value) {
  const keys = Object.keys(LIMIT_RANGES);
  assertExactKeys(value, keys, "limits");

  const normalized = {};
  for (const key of keys) {
    const [minimum, maximum] = LIMIT_RANGES[key];
    normalized[key] = assertBoundedInteger(
      value[key],
      minimum,
      maximum,
      `limits.${key}`
    );
  }
  return Object.freeze(normalized);
}

export function validateForwarderConfig(value) {
  if (!isRecord(value)) {
    fail("CONFIG_INVALID", "config must be an object");
  }

  let expectedListeners;
  let profile;
  if (value.schemaVersion === LEGACY_CONFIG_SCHEMA_VERSION) {
    assertExactKeys(
      value,
      [
        "schemaVersion",
        "bindAddress",
        "readinessToken",
        "readyFile",
        "listeners",
        "limits"
      ],
      "config"
    );
    expectedListeners = LEGACY_EXPECTED_LISTENERS;
  } else if (value.schemaVersion === PROFILED_CONFIG_SCHEMA_VERSION) {
    assertExactKeys(
      value,
      [
        "schemaVersion",
        "profile",
        "bindAddress",
        "readinessToken",
        "readyFile",
        "listeners",
        "limits"
      ],
      "config"
    );
    if (value.profile !== MEDIA_ONLY_PROFILE) {
      fail(
        "CONFIG_INVALID",
        `profile must be exactly ${MEDIA_ONLY_PROFILE}`
      );
    }
    profile = MEDIA_ONLY_PROFILE;
    expectedListeners = MEDIA_ONLY_EXPECTED_LISTENERS;
  } else {
    fail(
      "CONFIG_INVALID",
      `schemaVersion must be ${LEGACY_CONFIG_SCHEMA_VERSION} or ${PROFILED_CONFIG_SCHEMA_VERSION}`
    );
  }

  if (!isCanonicalRfc1918Host(value.bindAddress)) {
    fail(
      "CONFIG_INVALID",
      "bindAddress must be one canonical, usable RFC1918 IPv4 host address"
    );
  }
  if (
    typeof value.readyFile !== "string" ||
    value.readyFile.length === 0 ||
    value.readyFile.length > 32_767 ||
    !isAbsolute(value.readyFile)
  ) {
    fail("CONFIG_INVALID", "readyFile must be an absolute filesystem path");
  }
  if (!Array.isArray(value.listeners)) {
    fail("CONFIG_INVALID", "listeners must be an array");
  }
  if (value.listeners.length !== expectedListeners.length) {
    fail(
      "CONFIG_INVALID",
      `listeners must contain exactly ${expectedListeners.length} entries for schemaVersion ${value.schemaVersion}${profile ? ` profile ${profile}` : ""}`
    );
  }

  const listeners = value.listeners.map((listener, index) =>
    validateListener(listener, expectedListeners[index], index)
  );
  const ports = new Set(listeners.map(({ publicPort }) => publicPort));
  if (ports.size !== listeners.length) {
    fail("CONFIG_INVALID", "listener ports must be unique");
  }

  return Object.freeze({
    schemaVersion: value.schemaVersion,
    ...(profile ? { profile } : {}),
    bindAddress: value.bindAddress,
    readinessToken: validateReadinessToken(value.readinessToken),
    readyFile: value.readyFile,
    listeners: Object.freeze(listeners),
    limits: validateLimits(value.limits)
  });
}

/*
 * Schema v1 intentionally remains the exact five-listener release contract:
 * application, object storage, LiveKit signaling, and both LiveKit ICE
 * transports. Schema v2 is profile-gated so a media-only process cannot
 * silently bind a mixed or expanded listener set.
 */
function readinessEvidence(config, configSha256, processStartTimeUtc) {
  return Object.freeze({
    event: READY_EVENT,
    schemaVersion: config.schemaVersion,
    ...(config.profile ? { profile: config.profile } : {}),
    pid: process.pid,
    processStartTimeUtc,
    bindAddress: config.bindAddress,
    configSha256,
    readinessToken: config.readinessToken,
    listeners: config.listeners
  });
}

function stoppedEvidence(config, configSha256, reason) {
  return Object.freeze({
    event: STOPPED_EVENT,
    schemaVersion: config.schemaVersion,
    ...(config.profile ? { profile: config.profile } : {}),
    pid: process.pid,
    reason,
    configSha256
  });
}

export function parseForwarderConfigBytes(bytes) {
  let text;
  try {
    text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch (error) {
    fail("CONFIG_INVALID", "config file must be valid UTF-8", { cause: error });
  }

  let value;
  try {
    value = JSON.parse(text);
  } catch (error) {
    fail("CONFIG_INVALID", "config file must contain valid JSON", {
      cause: error
    });
  }
  return validateForwarderConfig(value);
}

export function sha256Hex(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function jsonLine(value) {
  return `${JSON.stringify(value)}\n`;
}

function delay(milliseconds) {
  return new Promise((resolveDelay) => {
    setTimeout(resolveDelay, milliseconds);
  });
}

async function pathExists(path) {
  try {
    await lstat(path);
    return true;
  } catch (error) {
    if (error?.code === "ENOENT") {
      return false;
    }
    throw error;
  }
}

async function writeReadyFileAtomically(path, line) {
  await mkdir(dirname(path), { recursive: true });
  if (await pathExists(path)) {
    fail(
      "READY_FILE_EXISTS",
      "readyFile already exists; refusing to overwrite unverified evidence"
    );
  }

  const temporaryPath =
    `${path}.${process.pid}.${randomBytes(8).toString("hex")}.tmp`;
  try {
    await writeFile(temporaryPath, line, {
      encoding: "utf8",
      flag: "wx",
      mode: 0o600
    });
    // Publishing a hard link is an atomic create-if-absent operation. Unlike
    // rename-overwrite, it cannot clobber evidence raced into place after the
    // stale-file check above. The temporary link is removed after publication.
    await link(temporaryPath, path);
    try {
      await unlink(temporaryPath);
    } catch {
      // Readiness is already complete and atomically visible. A retained
      // same-content temporary link is safer than withdrawing valid evidence.
    }
  } catch (error) {
    try {
      await unlink(temporaryPath);
    } catch (cleanupError) {
      if (cleanupError?.code !== "ENOENT") {
        // Preserve the original error: inability to publish readiness is fatal.
      }
    }
    if (error instanceof LanReleaseForwarderError) {
      throw error;
    }
    fail("READY_FILE_WRITE_FAILED", "could not publish readyFile atomically", {
      cause: error
    });
  }
}

function waitForTcpListen(server, listener, bindAddress, backlog) {
  return new Promise((resolveListen, rejectListen) => {
    const onError = (error) => {
      cleanup();
      rejectListen(error);
    };
    const onListening = () => {
      cleanup();
      resolveListen();
    };
    const cleanup = () => {
      server.off("error", onError);
      server.off("listening", onListening);
    };

    server.once("error", onError);
    server.once("listening", onListening);
    try {
      server.listen({
        host: bindAddress,
        port: listener.publicPort,
        backlog,
        exclusive: true
      });
    } catch (error) {
      cleanup();
      rejectListen(error);
    }
  });
}

function waitForUdpBind(socket, listener, bindAddress) {
  return new Promise((resolveBind, rejectBind) => {
    const onError = (error) => {
      cleanup();
      rejectBind(error);
    };
    const onListening = () => {
      cleanup();
      resolveBind();
    };
    const cleanup = () => {
      socket.off("error", onError);
      socket.off("listening", onListening);
    };

    socket.once("error", onError);
    socket.once("listening", onListening);
    try {
      socket.bind({
        address: bindAddress,
        port: listener.publicPort,
        exclusive: true
      });
    } catch (error) {
      cleanup();
      rejectBind(error);
    }
  });
}

function closeTcpServer(server) {
  return new Promise((resolveClose) => {
    try {
      server.close(() => resolveClose());
    } catch {
      resolveClose();
    }
  });
}

function closeUdpSocket(socket) {
  return new Promise((resolveClose) => {
    try {
      socket.close(() => resolveClose());
    } catch {
      resolveClose();
    }
  });
}

export class LanReleaseForwarder {
  constructor(config, configSha256, options = {}) {
    this.config = config;
    this.configSha256 = configSha256;
    this.processStartTimeUtc =
      options.processStartTimeUtc || PROCESS_START_TIME_UTC;
    this.emitStdout =
      options.emitStdout ||
      ((line) => {
        process.stdout.write(line);
      });
    this.emitStderr =
      options.emitStderr ||
      ((line) => {
        process.stderr.write(line);
      });

    this.accepting = false;
    this.stopping = false;
    this.readyWritten = false;
    this.tcpPairs = new Set();
    this.listenerEntries = [];
    this.stopPromise = undefined;
    this.resolveClosed = undefined;
    this.closed = new Promise((resolveClosed) => {
      this.resolveClosed = resolveClosed;
    });
  }

  async start() {
    try {
      await mkdir(dirname(this.config.readyFile), { recursive: true });
      if (await pathExists(this.config.readyFile)) {
        fail(
          "READY_FILE_EXISTS",
          "readyFile already exists; refusing to start with stale evidence"
        );
      }

      for (const listener of this.config.listeners) {
        if (listener.protocol === "tcp") {
          await this.startTcpListener(listener);
        } else {
          await this.startUdpListener(listener);
        }
      }

      this.accepting = true;
      const ready = readinessEvidence(
        this.config,
        this.configSha256,
        this.processStartTimeUtc
      );
      const line = jsonLine(ready);
      await writeReadyFileAtomically(this.config.readyFile, line);
      this.readyWritten = true;
      this.emitStdout(line);
      return this;
    } catch (error) {
      this.accepting = false;
      await this.closeImmediately();
      if (error instanceof LanReleaseForwarderError) {
        throw error;
      }
      fail("STARTUP_FAILED", "LAN release forwarder startup failed", {
        cause: error
      });
    }
  }

  async startTcpListener(listener) {
    const server = createServer(
      {
        allowHalfOpen: true,
        pauseOnConnect: true,
        highWaterMark: this.config.limits.socketHighWaterMarkBytes
      },
      (client) => this.acceptTcpClient(listener, client)
    );

    try {
      await waitForTcpListen(
        server,
        listener,
        this.config.bindAddress,
        this.config.limits.tcpBacklog
      );
    } catch (error) {
      try {
        server.close();
      } catch {
        // A failed bind has no open server to close.
      }
      fail(
        "LISTENER_BIND_FAILED",
        `could not bind ${listener.name}/tcp on ${this.config.bindAddress}:${listener.publicPort}`,
        { cause: error }
      );
    }

    const entry = { kind: "tcp", listener, server };
    this.listenerEntries.push(entry);
    server.on("error", (error) => {
      this.handleRuntimeListenerError(listener, error);
    });
  }

  acceptTcpClient(listener, client) {
    if (
      !this.accepting ||
      this.stopping ||
      this.tcpPairs.size >= this.config.limits.maxTcpConnections
    ) {
      client.destroy();
      return;
    }

    client.pause();
    client.setNoDelay(true);
    client.setKeepAlive(
      true,
      Math.min(this.config.limits.tcpIdleTimeoutMs, 30_000)
    );

    const upstream = createConnection({
      host: listener.targetHost,
      port: listener.targetPort,
      localAddress: LOOPBACK_TARGET,
      allowHalfOpen: true,
      highWaterMark: this.config.limits.socketHighWaterMarkBytes
    });
    upstream.setNoDelay(true);
    upstream.setKeepAlive(
      true,
      Math.min(this.config.limits.tcpIdleTimeoutMs, 30_000)
    );

    const pair = {
      client,
      upstream,
      connectTimer: undefined,
      closed: false,
      clientClosed: false,
      upstreamClosed: false
    };
    this.tcpPairs.add(pair);

    const finish = () => {
      if (pair.clientClosed && pair.upstreamClosed) {
        pair.closed = true;
        if (pair.connectTimer) {
          clearTimeout(pair.connectTimer);
          pair.connectTimer = undefined;
        }
        this.tcpPairs.delete(pair);
      }
    };
    const destroy = () => {
      client.destroy();
      upstream.destroy();
    };

    pair.connectTimer = setTimeout(
      destroy,
      this.config.limits.tcpConnectTimeoutMs
    );
    pair.connectTimer.unref();

    client.setTimeout(this.config.limits.tcpIdleTimeoutMs, destroy);
    upstream.setTimeout(this.config.limits.tcpIdleTimeoutMs, destroy);
    client.on("error", destroy);
    upstream.on("error", destroy);
    client.on("close", () => {
      pair.clientClosed = true;
      if (!upstream.destroyed && client.destroyed) {
        upstream.destroy();
      }
      finish();
    });
    upstream.on("close", () => {
      pair.upstreamClosed = true;
      if (!client.destroyed && upstream.destroyed) {
        client.destroy();
      }
      finish();
    });

    upstream.once("connect", () => {
      if (pair.connectTimer) {
        clearTimeout(pair.connectTimer);
        pair.connectTimer = undefined;
      }
      if (this.stopping || pair.closed) {
        destroy();
        return;
      }

      // Socket.pipe() applies Node stream backpressure in both directions.
      client.pipe(upstream);
      upstream.pipe(client);
      client.resume();
    });
  }

  async startUdpListener(listener) {
    const socket = createSocket({ type: "udp4", reuseAddr: false });
    try {
      await waitForUdpBind(socket, listener, this.config.bindAddress);
    } catch (error) {
      try {
        socket.close();
      } catch {
        // A failed bind has no open socket to close.
      }
      fail(
        "LISTENER_BIND_FAILED",
        `could not bind ${listener.name}/udp on ${this.config.bindAddress}:${listener.publicPort}`,
        { cause: error }
      );
    }

    const entry = {
      kind: "udp",
      listener,
      socket,
      mappings: new Map(),
      pendingUpstreamDatagrams: 0,
      pendingUpstreamBytes: 0,
      pendingPublicSends: 0,
      pendingPublicBytes: 0,
      reaper: undefined
    };
    this.listenerEntries.push(entry);

    socket.on("message", (message, remote) => {
      this.handleUdpClientDatagram(entry, message, remote);
    });
    socket.on("error", (error) => {
      this.handleRuntimeListenerError(listener, error);
    });

    const interval = Math.max(
      250,
      Math.min(
        1_000,
        Math.floor(this.config.limits.udpMappingIdleTimeoutMs / 2)
      )
    );
    entry.reaper = setInterval(() => {
      const staleBefore =
        Date.now() - this.config.limits.udpMappingIdleTimeoutMs;
      for (const mapping of entry.mappings.values()) {
        if (mapping.lastActivityAt <= staleBefore) {
          this.closeUdpMapping(entry, mapping);
        }
      }
    }, interval);
    entry.reaper.unref();
  }

  handleUdpClientDatagram(entry, message, remote) {
    if (
      !this.accepting ||
      this.stopping ||
      message.length > MAX_UDP_DATAGRAM_BYTES
    ) {
      return;
    }

    const key = `${remote.address}:${remote.port}`;
    let mapping = entry.mappings.get(key);
    if (!mapping) {
      if (
        entry.mappings.size >= this.config.limits.maxUdpMappings
      ) {
        return;
      }
      mapping = this.createUdpMapping(entry, key, remote);
    }

    mapping.lastActivityAt = Date.now();
    if (
      mapping.pendingUpstreamSends >=
        this.config.limits.maxUdpPendingDatagramsPerMapping ||
      entry.pendingUpstreamDatagrams >=
        this.config.limits.maxUdpPendingPublicDatagrams ||
      entry.pendingUpstreamBytes + message.length >
        MAX_UDP_PENDING_BYTES_GLOBAL
    ) {
      return;
    }

    mapping.pendingUpstreamSends += 1;
    entry.pendingUpstreamDatagrams += 1;
    entry.pendingUpstreamBytes += message.length;
    const ownedMessage = Buffer.from(message);
    if (!mapping.ready) {
      mapping.queue.push(ownedMessage);
      return;
    }
    this.sendUdpToUpstream(entry, mapping, ownedMessage);
  }

  createUdpMapping(entry, key, remote) {
    const socket = createSocket({ type: "udp4", reuseAddr: false });
    const mapping = {
      key,
      socket,
      remoteAddress: remote.address,
      remotePort: remote.port,
      ready: false,
      closed: false,
      queue: [],
      pendingUpstreamSends: 0,
      lastActivityAt: Date.now()
    };
    entry.mappings.set(key, mapping);

    socket.on("message", (message) => {
      if (
        mapping.closed ||
        this.stopping ||
        entry.pendingPublicSends >=
          this.config.limits.maxUdpPendingPublicDatagrams ||
        entry.pendingPublicBytes + message.length >
          MAX_UDP_PENDING_BYTES_GLOBAL
      ) {
        return;
      }

      mapping.lastActivityAt = Date.now();
      entry.pendingPublicSends += 1;
      entry.pendingPublicBytes += message.length;
      entry.socket.send(
        message,
        mapping.remotePort,
        mapping.remoteAddress,
        (error) => {
          entry.pendingPublicSends = Math.max(
            0,
            entry.pendingPublicSends - 1
          );
          entry.pendingPublicBytes = Math.max(
            0,
            entry.pendingPublicBytes - message.length
          );
          if (error) {
            this.closeUdpMapping(entry, mapping);
          }
        }
      );
    });
    socket.on("error", () => {
      this.closeUdpMapping(entry, mapping);
    });

    try {
      socket.bind(
        {
          address: LOOPBACK_TARGET,
          port: 0,
          exclusive: true
        },
        () => {
          if (mapping.closed || this.stopping) {
            this.closeUdpMapping(entry, mapping);
            return;
          }
          try {
            socket.connect(
              entry.listener.targetPort,
              entry.listener.targetHost,
              () => {
                if (mapping.closed || this.stopping) {
                  this.closeUdpMapping(entry, mapping);
                  return;
                }
                mapping.ready = true;
                const queued = mapping.queue.splice(0);
                for (const datagram of queued) {
                  this.sendUdpToUpstream(entry, mapping, datagram);
                }
              }
            );
          } catch {
            this.closeUdpMapping(entry, mapping);
          }
        }
      );
    } catch {
      this.closeUdpMapping(entry, mapping);
    }

    return mapping;
  }

  sendUdpToUpstream(entry, mapping, message) {
    if (mapping.closed || this.stopping) {
      this.completeUdpUpstreamSend(entry, mapping, message.length);
      return;
    }
    try {
      mapping.socket.send(message, (error) => {
        this.completeUdpUpstreamSend(entry, mapping, message.length);
        if (error) {
          this.closeUdpMapping(entry, mapping);
        }
      });
    } catch {
      this.completeUdpUpstreamSend(entry, mapping, message.length);
      this.closeUdpMapping(entry, mapping);
    }
  }

  completeUdpUpstreamSend(entry, mapping, byteLength) {
    mapping.pendingUpstreamSends = Math.max(
      0,
      mapping.pendingUpstreamSends - 1
    );
    entry.pendingUpstreamDatagrams = Math.max(
      0,
      entry.pendingUpstreamDatagrams - 1
    );
    entry.pendingUpstreamBytes = Math.max(
      0,
      entry.pendingUpstreamBytes - byteLength
    );
  }

  closeUdpMapping(entry, mapping) {
    if (mapping.closed) {
      return;
    }
    mapping.closed = true;
    for (const queued of mapping.queue) {
      this.completeUdpUpstreamSend(entry, mapping, queued.length);
    }
    mapping.queue.length = 0;
    if (entry.mappings.get(mapping.key) === mapping) {
      entry.mappings.delete(mapping.key);
    }
    try {
      mapping.socket.close();
    } catch {
      // A socket whose asynchronous bind failed may already be closed.
    }
  }

  handleRuntimeListenerError(listener, error) {
    if (this.stopping) {
      return;
    }
    const failure = new LanReleaseForwarderError(
      "RUNTIME_LISTENER_ERROR",
      `${listener.name}/${listener.protocol} listener failed`,
      { cause: error }
    );
    this.emitStderr(
      jsonLine({
        event: FATAL_EVENT,
        code: failure.code,
        message: failure.message
      })
    );
    void this.stop("runtime_listener_error", 1);
  }

  async removeOwnedReadyFile() {
    if (!this.readyWritten) {
      return;
    }
    try {
      const bytes = await readFile(this.config.readyFile);
      const value = JSON.parse(bytes.toString("utf8"));
      if (
        value?.event === READY_EVENT &&
        value?.pid === process.pid &&
        value?.configSha256 === this.configSha256 &&
        value?.readinessToken === this.config.readinessToken
      ) {
        await unlink(this.config.readyFile);
      }
    } catch (error) {
      if (error?.code !== "ENOENT") {
        // Never remove a file whose ownership evidence cannot be verified.
      }
    }
    this.readyWritten = false;
  }

  async closeImmediately() {
    for (const entry of this.listenerEntries) {
      if (entry.kind === "udp") {
        if (entry.reaper) {
          clearInterval(entry.reaper);
        }
        for (const mapping of [...entry.mappings.values()]) {
          this.closeUdpMapping(entry, mapping);
        }
      }
    }
    for (const pair of this.tcpPairs) {
      pair.client.destroy();
      pair.upstream.destroy();
    }

    const closes = this.listenerEntries.map((entry) =>
      entry.kind === "tcp"
        ? closeTcpServer(entry.server)
        : closeUdpSocket(entry.socket)
    );
    await Promise.race([
      Promise.allSettled(closes),
      delay(Math.max(250, this.config.limits.tcpShutdownGraceMs))
    ]);
    this.listenerEntries.length = 0;
    await this.removeOwnedReadyFile();
  }

  stop(reason = "requested", exitCode = 0) {
    if (this.stopPromise) {
      return this.stopPromise;
    }
    this.stopPromise = this.performStop(reason, exitCode);
    return this.stopPromise;
  }

  async performStop(reason, exitCode) {
    this.stopping = true;
    this.accepting = false;

    for (const entry of this.listenerEntries) {
      if (entry.kind === "udp") {
        if (entry.reaper) {
          clearInterval(entry.reaper);
        }
        for (const mapping of [...entry.mappings.values()]) {
          this.closeUdpMapping(entry, mapping);
        }
      }
    }

    const closes = this.listenerEntries.map((entry) =>
      entry.kind === "tcp"
        ? closeTcpServer(entry.server)
        : closeUdpSocket(entry.socket)
    );
    const grace = this.config.limits.tcpShutdownGraceMs;
    await Promise.race([Promise.allSettled(closes), delay(grace)]);

    for (const pair of this.tcpPairs) {
      pair.client.destroy();
      pair.upstream.destroy();
    }
    await Promise.race([
      Promise.allSettled(closes),
      delay(Math.min(1_000, grace))
    ]);

    this.listenerEntries.length = 0;
    await this.removeOwnedReadyFile();
    const stopped = stoppedEvidence(
      this.config,
      this.configSha256,
      reason
    );
    this.emitStdout(jsonLine(stopped));
    const result = Object.freeze({ exitCode, reason });
    this.resolveClosed(result);
    return result;
  }
}

export async function startLanReleaseForwarder(configPath, options = {}) {
  if (
    typeof configPath !== "string" ||
    configPath.length === 0 ||
    !isAbsolute(configPath)
  ) {
    fail("CONFIG_PATH_INVALID", "--config must be an absolute path");
  }

  let bytes;
  try {
    bytes = await readFile(configPath);
  } catch (error) {
    fail("CONFIG_READ_FAILED", "could not read the config file", {
      cause: error
    });
  }
  const config = parseForwarderConfigBytes(bytes);
  const forwarder = new LanReleaseForwarder(
    config,
    sha256Hex(bytes),
    options
  );
  return forwarder.start();
}

export function parseCliConfigPath(args) {
  if (
    args.length === 2 &&
    args[0] === "--config" &&
    args[1] &&
    !args[1].startsWith("--")
  ) {
    return args[1];
  }
  if (
    args.length === 1 &&
    args[0].startsWith("--config=") &&
    args[0].length > "--config=".length
  ) {
    return args[0].slice("--config=".length);
  }
  fail(
    "CLI_INVALID",
    "usage: node scripts/lan_release_forwarder.mjs --config <absolute-json>"
  );
}

function emitFatal(error) {
  const code =
    error instanceof LanReleaseForwarderError
      ? error.code
      : "UNEXPECTED_FAILURE";
  const message =
    error instanceof Error ? error.message : "unexpected forwarder failure";
  process.stderr.write(
    jsonLine({
      event: FATAL_EVENT,
      code,
      message
    })
  );
}

export async function runCli(args = process.argv.slice(2)) {
  let forwarder;
  try {
    const configPath = parseCliConfigPath(args);
    forwarder = await startLanReleaseForwarder(configPath);
  } catch (error) {
    emitFatal(error);
    process.exitCode = 1;
    return;
  }

  const requestStop = (signal) => {
    void forwarder.stop(signal.toLowerCase(), 0);
  };
  process.once("SIGINT", () => requestStop("SIGINT"));
  process.once("SIGTERM", () => requestStop("SIGTERM"));

  const result = await forwarder.closed;
  process.exitCode = result.exitCode;
}

const invokedAsScript =
  Boolean(process.argv[1]) &&
  pathToFileURL(resolve(process.argv[1])).href === import.meta.url;
if (invokedAsScript) {
  await runCli();
}
