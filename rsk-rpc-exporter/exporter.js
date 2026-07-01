const express = require('express');
const { Registry, Gauge, collectDefaultMetrics } = require('prom-client');
const axios = require('axios');
const { exec } = require('child_process');
const util = require('util');
const execPromise = util.promisify(exec);

const app = express();
const port = process.env.PORT || 9090;
const rpcUrls = (process.env.RPC_URLS || 'http://rskj-miner1:4444').split(',');

const register = new Registry();
collectDefaultMetrics({ register });

// --- Metrics ---

const pendingTransactions = new Gauge({
    name: 'rsk_txpool_pending_transactions',
    help: 'Number of pending transactions in the mempool',
    labelNames: ['node'],
});

const nmtMetric = new Gauge({
    name: 'rsk_jvm_nmt_bytes',
    help: 'JVM Native Memory Tracking metrics in bytes',
    labelNames: ['node', 'category', 'type'], // type: reserved | committed
});

const heapObjectsCount = new Gauge({
    name: 'rsk_jvm_heap_objects_count',
    help: 'JVM Heap object instance count by package',
    labelNames: ['node', 'package'],
});

const heapObjectsBytes = new Gauge({
    name: 'rsk_jvm_heap_objects_bytes',
    help: 'JVM Heap object bytes by package',
    labelNames: ['node', 'package'],
});

const heapClassObjectsCount = new Gauge({
    name: 'rsk_jvm_heap_class_objects_count',
    help: 'JVM Heap object instance count by specific class',
    labelNames: ['node', 'package', 'class'],
});

const heapClassObjectsBytes = new Gauge({
    name: 'rsk_jvm_heap_class_objects_bytes',
    help: 'JVM Heap object bytes by specific class',
    labelNames: ['node', 'package', 'class'],
});

register.registerMetric(pendingTransactions);
register.registerMetric(nmtMetric);
register.registerMetric(heapObjectsCount);
register.registerMetric(heapObjectsBytes);
register.registerMetric(heapClassObjectsCount);
register.registerMetric(heapClassObjectsBytes);

// --- Helpers ---

async function getNMTData(containerName) {
    try {
        // We use jattach to trigger jcmd VM.native_memory summary
        // jattach <pid> <cmd> <args>
        const { stdout } = await execPromise(`docker exec ${containerName} jattach 1 jcmd "VM.native_memory summary"`);
        return stdout;
    } catch (error) {
        console.error(`Error getting NMT from ${containerName}: ${error.message}`);
        return null;
    }
}

function parseNMT(nodeName, stdout) {
    if (!stdout) return;

    const lines = stdout.split('\n');
    let currentCategory = '';

    lines.forEach(line => {
        // Match category lines like "-                 Internal (reserved=629MB, committed=377MB)"
        const catMatch = line.match(/^\-\s+(.+?)\s+\(reserved=(\d+)(KB|MB|GB), committed=(\d+)(KB|MB|GB)\)/);
        if (catMatch) {
            currentCategory = catMatch[1].trim().toLowerCase().replace(/ /g, '_');
            const reserved = convertToBytes(catMatch[2], catMatch[3]);
            const committed = convertToBytes(catMatch[4], catMatch[5]);

            nmtMetric.set({ node: nodeName, category: currentCategory, type: 'reserved' }, reserved);
            nmtMetric.set({ node: nodeName, category: currentCategory, type: 'committed' }, committed);
        }

        // Match total line: "Total: reserved=5381MB, committed=3912MB"
        const totalMatch = line.match(/^Total:\s+reserved=(\d+)(KB|MB|GB),\s+committed=(\d+)(KB|MB|GB)/);
        if (totalMatch) {
            const reserved = convertToBytes(totalMatch[1], totalMatch[2]);
            const committed = convertToBytes(totalMatch[3], totalMatch[4]);

            nmtMetric.set({ node: nodeName, category: 'total', type: 'reserved' }, reserved);
            nmtMetric.set({ node: nodeName, category: 'total', type: 'committed' }, committed);
        }
    });
}

function convertToBytes(value, unit) {
    const val = parseInt(value, 10);
    switch (unit) {
        case 'KB': return val * 1024;
        case 'MB': return val * 1024 * 1024;
        case 'GB': return val * 1024 * 1024 * 1024;
        default: return val;
    }
}

// --- Main Cycles ---

async function updateRPCMetrics() {
    for (const url of rpcUrls) {
        const nodeName = url.split('//')[1].split(':')[0];
        try {
            const response = await axios.post(url, {
                jsonrpc: '2.0',
                method: 'txpool_status',
                params: [],
                id: 1,
            }, { timeout: 2000 });

            if (response.data && response.data.result) {
                const pending = parseInt(response.data.result.pending, 16);
                pendingTransactions.set({ node: nodeName }, pending);
            }
        } catch (error) {
            // Ignore RPC errors for now to keep logs clean during startup
        }
    }
}

async function updateNMTMetrics() {
    for (const url of rpcUrls) {
        const nodeName = url.split('//')[1].split(':')[0];
        const stdout = await getNMTData(nodeName);
        if (stdout) {
            parseNMT(nodeName, stdout);
        }
    }
}

async function getHeapHistogram(containerName) {
    try {
        const { stdout } = await execPromise(`docker exec ${containerName} jattach 1 jcmd "GC.class_histogram"`, { maxBuffer: 1024 * 1024 * 10 });
        return stdout;
    } catch (error) {
        console.error(`Error getting Heap Histogram from ${containerName}: ${error.message}`);
        return null;
    }
}

function parseHeapHistogram(nodeName, stdout) {
    if (!stdout) return;

    const lines = stdout.split('\n');
    let pkgStats = {};
    let trackedClassesStats = {};

    lines.forEach(line => {
        // Match lines like: "   1:        123456       12345678  co.rsk.crypto.Keccak256"
        const match = line.match(/^\s*\d+:\s+(\d+)\s+(\d+)\s+(.+)$/);
        if (match) {
            const instances = parseInt(match[1], 10);
            const bytes = parseInt(match[2], 10);
            const className = match[3].trim();
            
            if (className.startsWith('co.rsk.')) {
                // e.g. co.rsk.crypto.Keccak256 -> crypto
                const parts = className.split('.');
                if (parts.length > 2) {
                    let pkg = parts[2]; 
                    
                    // Prevent label cardinality explosion from root classes or dynamic lambdas
                    if (!pkg || pkg.includes('$') || pkg.includes('/') || pkg.charAt(0) !== pkg.charAt(0).toLowerCase()) {
                        pkg = 'root';
                    }

                    if (!pkgStats[pkg]) {
                        pkgStats[pkg] = { count: 0, bytes: 0 };
                    }
                    pkgStats[pkg].count += instances;
                    pkgStats[pkg].bytes += bytes;

                    // Track individual classes for targeted packages
                    if (pkg === 'crypto' || pkg === 'core') {
                        let cleanClass = parts.slice(3).join('.');
                        if (!cleanClass || cleanClass.includes('/')) return; // skip lambdas for class granular level
                        
                        if (!trackedClassesStats[pkg]) trackedClassesStats[pkg] = {};
                        if (!trackedClassesStats[pkg][cleanClass]) trackedClassesStats[pkg][cleanClass] = { count: 0, bytes: 0 };
                        trackedClassesStats[pkg][cleanClass].count += instances;
                        trackedClassesStats[pkg][cleanClass].bytes += bytes;
                    }
                }
            }
        }
    });

    for (const [pkg, stats] of Object.entries(pkgStats)) {
        heapObjectsCount.set({ node: nodeName, package: pkg }, stats.count);
        heapObjectsBytes.set({ node: nodeName, package: pkg }, stats.bytes);
    }
    
    for (const [pkg, classMap] of Object.entries(trackedClassesStats)) {
        for (const [cls, classStats] of Object.entries(classMap)) {
            heapClassObjectsCount.set({ node: nodeName, package: pkg, class: cls }, classStats.count);
            heapClassObjectsBytes.set({ node: nodeName, package: pkg, class: cls }, classStats.bytes);
        }
    }
}

async function updateHeapMetrics() {
    for (const url of rpcUrls) {
        const nodeName = url.split('//')[1].split(':')[0];
        const stdout = await getHeapHistogram(nodeName);
        if (stdout) {
            parseHeapHistogram(nodeName, stdout);
        }
    }
}

// Update metrics periodically
setInterval(updateRPCMetrics, 5000);
updateRPCMetrics();
setInterval(updateNMTMetrics, 10000);
updateNMTMetrics();
setInterval(updateHeapMetrics, 60000);
updateHeapMetrics();


app.get('/metrics', async (req, res) => {
    try {
        res.set('Content-Type', register.contentType);
        res.end(await register.metrics());
    } catch (ex) {
        res.status(500).end(ex);
    }
});

app.listen(port, '0.0.0.0', () => {
    console.log(`RSK RPC + NMT Exporter listening on port ${port}`);
});
