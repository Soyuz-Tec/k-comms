import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createSocket } from "node:dgram";
import {
  access,
  mkdtemp,
  readFile,
  rm,
  writeFile
} from "node:fs/promises";
import { createConnection, createServer } from "node:net";
import { networkInterfaces, tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

import {
  isCanonicalRfc1918Host,
  sha256Hex,
  startLanReleaseForwarder,
  validateForwarderConfig
} from "./lan_release_forwarder.mjs";

const LOOPBACK = "127.0.0.1";
const SCRIPT_PATH = fileURLToPath(
  new URL("./lan_release_forwarder.mjs", import.meta.url)
);

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

function listenTcp(server, host, port = 0) {
  return new Promise((resolveListen, rejectListen) => {
    const onError = (error) => {
      cleanup();
      rejectListen(error);
    };
    const onListening = () => {
      cleanup();
      resolveListen(server.address().port);
    };
    const cleanup = () => {
      server.off("error", onError);
      server.off("listening", onListening);
    };
    server.once("error", onError);
    server.once("listening", onListening);
    server.listen({ host, port, exclusive: true });
  });
}

function bindUdp(socket, host, port = 0) {
  return new Promise((resolveBind, rejectBind) => {
    const onError = (error) => {
      cleanup();
      rejectBind(error);
    };
    const onListening = () => {
      cleanup();
      resolveBind(socket.address().port);
    };
    const cleanup = () => {
      socket.off("error", onError);
      socket.off("listening", onListening);
    };
    socket.once("error", onError);
    socket.once("listening", onListening);
    socket.bind({ address: host, port, exclusive: true });
  });
}

async function createTcpEchoTarget(index) {
  const greeting = Buffer.from(`target-${index}-ready|`);
  const server = createServer({ allowHalfOpen: true }, (socket) => {
    socket.write(greeting);
    socket.on("data", (chunk) => {
      socket.write(chunk);
    });
    socket.on("end", () => socket.end());
    socket.on("error", () => socket.destroy());
  });
  const port = await listenTcp(server, LOOPBACK);
  return { server, port, greeting };
}

async function createUniqueUdpEchoTarget(usedPorts) {
  for (;;) {
    const socket = createSocket({ type: "udp4", reuseAddr: false });
    const port = await bindUdp(socket, LOOPBACK);
    if (usedPorts.has(port)) {
      await closeUdpSocket(socket);
      continue;
    }
    socket.on("message", (message, remote) => {
      socket.send(message, remote.port, remote.address);
    });
    return { socket, port };
  }
}

function selectPrivateBindAddress() {
  const explicit = process.env.LAN_FORWARDER_TEST_BIND_ADDRESS;
  if (explicit) {
    assert.ok(
      isCanonicalRfc1918Host(explicit),
      "LAN_FORWARDER_TEST_BIND_ADDRESS must be canonical RFC1918 IPv4"
    );
    return explicit;
  }

  const addresses = [];
  for (const [interfaceName, records] of Object.entries(networkInterfaces())) {
    for (const record of records || []) {
      if (
        record.family === "IPv4" &&
        !record.internal &&
        isCanonicalRfc1918Host(record.address)
      ) {
        addresses.push({
          interfaceName,
          address: record.address,
          preference: record.address.startsWith("192.168.")
            ? 0
            : record.address.startsWith("10.")
              ? 1
              : 2
        });
      }
    }
  }
  addresses.sort(
    (left, right) =>
      left.preference - right.preference ||
      left.interfaceName.localeCompare(right.interfaceName) ||
      left.address.localeCompare(right.address)
  );
  assert.ok(
    addresses.length > 0,
    "forwarding self-test requires one assigned RFC1918 IPv4 interface"
  );
  return addresses[0].address;
}

function makeConfig({ bindAddress, readyFile, ports }) {
  const listenerSpecs = [
    ["app", "tcp", ports[0]],
    ["minio", "tcp", ports[1]],
    ["livekitSignal", "tcp", ports[2]],
    ["livekitTcp", "tcp", ports[3]],
    ["livekitUdp", "udp", ports[4]]
  ];
  return {
    schemaVersion: 1,
    bindAddress,
    readinessToken: "deterministic-test-readiness-token",
    readyFile,
    listeners: listenerSpecs.map(([name, protocol, port]) => ({
      name,
      protocol,
      publicPort: port,
      targetHost: LOOPBACK,
      targetPort: port
    })),
    limits: {
      maxTcpConnections: 2,
      tcpConnectTimeoutMs: 1_000,
      tcpIdleTimeoutMs: 3_000,
      tcpShutdownGraceMs: 500,
      tcpBacklog: 16,
      socketHighWaterMarkBytes: 4_096,
      maxUdpMappings: 2,
      udpMappingIdleTimeoutMs: 1_000,
      maxUdpPendingDatagramsPerMapping: 4,
      maxUdpPendingPublicDatagrams: 8
    }
  };
}

async function writeConfig(path, config) {
  const bytes = Buffer.from(`${JSON.stringify(config, null, 2)}\n`, "utf8");
  await writeFile(path, bytes, { flag: "wx" });
  return bytes;
}

async function assertPathMissing(path) {
  await assert.rejects(access(path), (error) => error?.code === "ENOENT");
}

async function tcpRoundTrip({
  bindAddress,
  listener,
  greeting,
  payload
}) {
  const expectedLength = greeting.length + payload.length;
  return new Promise((resolveRoundTrip, rejectRoundTrip) => {
    const chunks = [];
    let receivedLength = 0;
    const socket = createConnection({
      host: bindAddress,
      port: listener.publicPort,
      localAddress: bindAddress
    });
    const timeout = setTimeout(() => {
      socket.destroy();
      rejectRoundTrip(new Error(`TCP ${listener.name} round-trip timed out`));
    }, 4_000);

    socket.on("connect", () => {
      socket.write(payload);
    });
    socket.on("data", (chunk) => {
      chunks.push(chunk);
      receivedLength += chunk.length;
      if (receivedLength >= expectedLength) {
        clearTimeout(timeout);
        const received = Buffer.concat(chunks);
        socket.end();
        resolveRoundTrip(received);
      }
    });
    socket.on("error", (error) => {
      clearTimeout(timeout);
      rejectRoundTrip(error);
    });
  });
}

function openHeldTcpConnection(bindAddress, port, greeting) {
  return new Promise((resolveConnection, rejectConnection) => {
    const socket = createConnection({
      host: bindAddress,
      port,
      localAddress: bindAddress
    });
    const chunks = [];
    let receivedLength = 0;
    const timeout = setTimeout(() => {
      socket.destroy();
      rejectConnection(new Error("held TCP connection timed out"));
    }, 2_000);
    socket.on("data", (chunk) => {
      chunks.push(chunk);
      receivedLength += chunk.length;
      if (receivedLength >= greeting.length) {
        clearTimeout(timeout);
        assert.deepEqual(
          Buffer.concat(chunks).subarray(0, greeting.length),
          greeting
        );
        resolveConnection(socket);
      }
    });
    socket.on("error", (error) => {
      clearTimeout(timeout);
      rejectConnection(error);
    });
  });
}

function waitForRejectedTcpConnection(bindAddress, port) {
  return new Promise((resolveRejected, rejectRejected) => {
    const socket = createConnection({
      host: bindAddress,
      port,
      localAddress: bindAddress
    });
    const timeout = setTimeout(() => {
      socket.destroy();
      rejectRejected(new Error("over-cap TCP connection was not closed"));
    }, 2_000);
    const rejected = () => {
      clearTimeout(timeout);
      socket.destroy();
      resolveRejected();
    };
    socket.on("close", rejected);
    socket.on("error", rejected);
  });
}

async function createUdpClient(bindAddress) {
  const socket = createSocket({ type: "udp4", reuseAddr: false });
  await bindUdp(socket, bindAddress);
  return socket;
}

function udpRoundTrip(socket, bindAddress, port, payload, timeoutMs = 1_000) {
  return new Promise((resolveRoundTrip, rejectRoundTrip) => {
    const timeout = setTimeout(() => {
      cleanup();
      rejectRoundTrip(new Error("UDP round-trip timed out"));
    }, timeoutMs);
    const onMessage = (message) => {
      cleanup();
      resolveRoundTrip(message);
    };
    const onError = (error) => {
      cleanup();
      rejectRoundTrip(error);
    };
    const cleanup = () => {
      clearTimeout(timeout);
      socket.off("message", onMessage);
      socket.off("error", onError);
    };

    socket.once("message", onMessage);
    socket.once("error", onError);
    socket.send(payload, port, bindAddress, (error) => {
      if (error) {
        cleanup();
        rejectRoundTrip(error);
      }
    });
  });
}

async function waitUntil(predicate, timeoutMs, description) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) {
      return;
    }
    await new Promise((resolveDelay) => setTimeout(resolveDelay, 25));
  }
  assert.fail(`timed out waiting for ${description}`);
}

async function assertTcpPortCanBind(bindAddress, port) {
  const server = createServer();
  try {
    await listenTcp(server, bindAddress, port);
  } finally {
    await closeTcpServer(server);
  }
}

async function assertUdpPortCanBind(bindAddress, port) {
  const socket = createSocket({ type: "udp4", reuseAddr: false });
  try {
    await bindUdp(socket, bindAddress, port);
  } finally {
    await closeUdpSocket(socket);
  }
}

function runChild(args, cwd, timeoutMs = 5_000) {
  return new Promise((resolveRun, rejectRun) => {
    const child = spawn(process.execPath, args, {
      cwd,
      windowsHide: true,
      stdio: ["ignore", "pipe", "pipe"]
    });
    const stdout = [];
    const stderr = [];
    child.stdout.on("data", (chunk) => stdout.push(chunk));
    child.stderr.on("data", (chunk) => stderr.push(chunk));
    const timeout = setTimeout(() => {
      child.kill();
      rejectRun(new Error("child forwarder test timed out"));
    }, timeoutMs);
    child.on("error", (error) => {
      clearTimeout(timeout);
      rejectRun(error);
    });
    child.on("close", (code, signal) => {
      clearTimeout(timeout);
      resolveRun({
        code,
        signal,
        stdout: Buffer.concat(stdout).toString("utf8"),
        stderr: Buffer.concat(stderr).toString("utf8")
      });
    });
  });
}

test(
  "LAN release forwarder validates, forwards TCP/UDP, and cleans up",
  { timeout: 30_000 },
  async (t) => {
    const bindAddress = selectPrivateBindAddress();
    const temporaryDirectory = await mkdtemp(
      join(tmpdir(), "lan-release-forwarder-")
    );
    t.after(async () => {
      await rm(temporaryDirectory, { force: true, recursive: true });
    });

    const tcpTargets = [];
    for (let index = 0; index < 4; index += 1) {
      tcpTargets.push(await createTcpEchoTarget(index));
    }
    const usedPorts = new Set(tcpTargets.map(({ port }) => port));
    const udpTarget = await createUniqueUdpEchoTarget(usedPorts);
    const ports = [...usedPorts, udpTarget.port];
    t.after(async () => {
      await Promise.all(
        tcpTargets.map(({ server }) => closeTcpServer(server))
      );
      await closeUdpSocket(udpTarget.socket);
    });

    const baseConfig = makeConfig({
      bindAddress,
      readyFile: join(temporaryDirectory, "base.ready.json"),
      ports
    });

    await t.test("rejects wildcard, DNS, public, reserved, and noncanonical binds", () => {
      for (const invalidAddress of [
        "0.0.0.0",
        "lan-host.example",
        "8.8.8.8",
        "127.0.0.1",
        "169.254.10.20",
        "100.64.1.2",
        "192.0.2.10",
        "224.0.0.1",
        "192.168.001.10",
        " 192.168.1.10",
        "::"
      ]) {
        const candidate = structuredClone(baseConfig);
        candidate.bindAddress = invalidAddress;
        assert.throws(
          () => validateForwarderConfig(candidate),
          (error) =>
            error?.code === "CONFIG_INVALID" &&
            /bindAddress/.test(error.message),
          invalidAddress
        );
      }

      for (const validAddress of [
        "10.0.0.0",
        "10.255.255.255",
        "172.16.0.0",
        "172.31.255.255",
        "192.168.0.0",
        "192.168.255.255"
      ]) {
        assert.equal(isCanonicalRfc1918Host(validAddress), true, validAddress);
      }

      const nonLoopbackTarget = structuredClone(baseConfig);
      nonLoopbackTarget.listeners[0].targetHost = "0.0.0.0";
      assert.throws(
        () => validateForwarderConfig(nonLoopbackTarget),
        (error) => error?.code === "CONFIG_INVALID"
      );

      const remappedPort = structuredClone(baseConfig);
      remappedPort.listeners[0].targetPort += 1;
      assert.throws(
        () => validateForwarderConfig(remappedPort),
        (error) => error?.code === "CONFIG_INVALID"
      );
    });

    await t.test("CLI reports invalid config as machine-readable fatal evidence", async () => {
      const invalidPath = join(temporaryDirectory, "invalid.json");
      const invalid = structuredClone(baseConfig);
      invalid.bindAddress = "0.0.0.0";
      invalid.readyFile = join(temporaryDirectory, "invalid.ready.json");
      await writeConfig(invalidPath, invalid);
      const result = await runChild(
        [SCRIPT_PATH, "--config", invalidPath],
        dirname(SCRIPT_PATH)
      );
      assert.equal(result.code, 1);
      assert.equal(result.stdout, "");
      const fatal = JSON.parse(result.stderr.trim());
      assert.equal(fatal.event, "lan_release_forwarder_fatal");
      assert.equal(fatal.code, "CONFIG_INVALID");
      await assertPathMissing(invalid.readyFile);
    });

    await t.test("refuses stale readiness without opening listeners", async () => {
      const stalePath = join(temporaryDirectory, "stale.ready.json");
      const configPath = join(temporaryDirectory, "stale.config.json");
      const config = structuredClone(baseConfig);
      config.readyFile = stalePath;
      await writeFile(stalePath, '{"event":"stale"}\n', "utf8");
      await writeConfig(configPath, config);
      await assert.rejects(
        startLanReleaseForwarder(configPath, {
          emitStdout() {},
          emitStderr() {}
        }),
        (error) => error?.code === "READY_FILE_EXISTS"
      );
      await assertTcpPortCanBind(bindAddress, ports[0]);
      assert.equal(await readFile(stalePath, "utf8"), '{"event":"stale"}\n');
    });

    await t.test("bind collision fails closed and releases earlier listeners", async () => {
      const collision = createServer();
      await listenTcp(collision, bindAddress, ports[2]);
      const readyFile = join(temporaryDirectory, "collision.ready.json");
      const configPath = join(temporaryDirectory, "collision.config.json");
      const config = structuredClone(baseConfig);
      config.readyFile = readyFile;
      await writeConfig(configPath, config);
      await assert.rejects(
        startLanReleaseForwarder(configPath, {
          emitStdout() {},
          emitStderr() {}
        }),
        (error) => error?.code === "LISTENER_BIND_FAILED"
      );
      await assertPathMissing(readyFile);
      await closeTcpServer(collision);

      for (let index = 0; index < 4; index += 1) {
        await assertTcpPortCanBind(bindAddress, ports[index]);
      }
      await assertUdpPortCanBind(bindAddress, ports[4]);
    });

    await t.test("forwards all transports with bounded UDP NAT and owned readiness", async () => {
      const readyFile = join(temporaryDirectory, "success.ready.json");
      const configPath = join(temporaryDirectory, "success.config.json");
      const config = structuredClone(baseConfig);
      config.readyFile = readyFile;
      const configBytes = await writeConfig(configPath, config);
      const stdout = [];
      const stderr = [];
      const forwarder = await startLanReleaseForwarder(configPath, {
        emitStdout(line) {
          stdout.push(line);
        },
        emitStderr(line) {
          stderr.push(line);
        }
      });

      const readyLine = await readFile(readyFile, "utf8");
      assert.equal(stdout[0], readyLine);
      const ready = JSON.parse(readyLine);
      assert.equal(ready.event, "lan_release_forwarder_ready");
      assert.equal(ready.schemaVersion, 1);
      assert.equal(ready.pid, process.pid);
      assert.equal(ready.bindAddress, bindAddress);
      assert.equal(ready.readinessToken, config.readinessToken);
      assert.equal(ready.configSha256, sha256Hex(configBytes));
      assert.deepEqual(ready.listeners, config.listeners);
      assert.ok(
        Math.abs(
          Date.parse(ready.processStartTimeUtc) -
            (Date.now() - process.uptime() * 1_000)
        ) <= 5_000,
        "ready processStartTimeUtc must identify this Node process"
      );

      for (let index = 0; index < 4; index += 1) {
        const payload =
          index === 0
            ? Buffer.alloc(512 * 1_024, 0x61)
            : Buffer.from(`tcp-${config.listeners[index].name}`);
        const received = await tcpRoundTrip({
          bindAddress,
          listener: config.listeners[index],
          greeting: tcpTargets[index].greeting,
          payload
        });
        assert.deepEqual(
          received,
          Buffer.concat([tcpTargets[index].greeting, payload])
        );
      }

      await waitUntil(
        () => forwarder.tcpPairs.size === 0,
        2_000,
        "completed TCP round trips to close"
      );
      const heldTcpClients = await Promise.all([
        openHeldTcpConnection(
          bindAddress,
          config.listeners[0].publicPort,
          tcpTargets[0].greeting
        ),
        openHeldTcpConnection(
          bindAddress,
          config.listeners[0].publicPort,
          tcpTargets[0].greeting
        )
      ]);
      await waitUntil(
        () => forwarder.tcpPairs.size === config.limits.maxTcpConnections,
        1_000,
        "global TCP connection cap to be occupied"
      );
      await waitForRejectedTcpConnection(
        bindAddress,
        config.listeners[0].publicPort
      );
      assert.equal(
        forwarder.tcpPairs.size,
        config.limits.maxTcpConnections
      );
      for (const socket of heldTcpClients) {
        socket.destroy();
      }
      await waitUntil(
        () => forwarder.tcpPairs.size === 0,
        2_000,
        "held TCP connections to close"
      );

      const udpEntry = forwarder.listenerEntries.find(
        ({ listener }) => listener.name === "livekitUdp"
      );
      assert.ok(udpEntry, "UDP listener must be active");
      const udpClients = [
        await createUdpClient(bindAddress),
        await createUdpClient(bindAddress),
        await createUdpClient(bindAddress)
      ];
      t.after(async () => {
        await Promise.all(udpClients.map(closeUdpSocket));
      });

      const udpPayloads = [
        Buffer.from("udp-client-0"),
        Buffer.from("udp-client-1")
      ];
      const udpReplies = await Promise.all(
        udpPayloads.map((payload, index) =>
          udpRoundTrip(
            udpClients[index],
            bindAddress,
            config.listeners[4].publicPort,
            payload
          )
        )
      );
      for (let index = 0; index < udpPayloads.length; index += 1) {
        assert.deepEqual(udpReplies[index], udpPayloads[index]);
      }
      assert.equal(udpEntry.mappings.size, 2);
      await assert.rejects(
        udpRoundTrip(
          udpClients[2],
          bindAddress,
          config.listeners[4].publicPort,
          Buffer.from("must-drop-at-cap"),
          250
        ),
        /timed out/
      );
      assert.equal(udpEntry.mappings.size, 2);

      await waitUntil(
        () => udpEntry.mappings.size === 0,
        3_000,
        "idle UDP mappings to expire"
      );
      const afterExpiry = Buffer.from("udp-after-expiry");
      assert.deepEqual(
        await udpRoundTrip(
          udpClients[2],
          bindAddress,
          config.listeners[4].publicPort,
          afterExpiry
        ),
        afterExpiry
      );
      assert.equal(udpEntry.mappings.size, 1);

      const stopResult = await forwarder.stop("self_test", 0);
      assert.deepEqual(stopResult, { exitCode: 0, reason: "self_test" });
      assert.equal(stderr.length, 0);
      assert.equal(
        JSON.parse(stdout.at(-1)).event,
        "lan_release_forwarder_stopped"
      );
      await assertPathMissing(readyFile);

      for (let index = 0; index < 4; index += 1) {
        await assertTcpPortCanBind(bindAddress, ports[index]);
      }
      await assertUdpPortCanBind(bindAddress, ports[4]);

      const runtimeReadyFile = join(
        temporaryDirectory,
        "runtime-error.ready.json"
      );
      const runtimeConfigPath = join(
        temporaryDirectory,
        "runtime-error.config.json"
      );
      const runtimeConfig = structuredClone(baseConfig);
      runtimeConfig.readyFile = runtimeReadyFile;
      await writeConfig(runtimeConfigPath, runtimeConfig);
      const runtimeStdout = [];
      const runtimeStderr = [];
      const runtimeForwarder = await startLanReleaseForwarder(
        runtimeConfigPath,
        {
          emitStdout(line) {
            runtimeStdout.push(line);
          },
          emitStderr(line) {
            runtimeStderr.push(line);
          }
        }
      );
      const runtimeUdpEntry = runtimeForwarder.listenerEntries.find(
        ({ listener }) => listener.name === "livekitUdp"
      );
      runtimeUdpEntry.socket.emit(
        "error",
        new Error("deterministic runtime listener failure")
      );
      assert.deepEqual(await runtimeForwarder.closed, {
        exitCode: 1,
        reason: "runtime_listener_error"
      });
      assert.equal(
        JSON.parse(runtimeStderr.at(-1)).event,
        "lan_release_forwarder_fatal"
      );
      assert.equal(
        JSON.parse(runtimeStdout.at(-1)).event,
        "lan_release_forwarder_stopped"
      );
      await assertPathMissing(runtimeReadyFile);
      for (let index = 0; index < 4; index += 1) {
        await assertTcpPortCanBind(bindAddress, ports[index]);
      }
      await assertUdpPortCanBind(bindAddress, ports[4]);
    });
  }
);
