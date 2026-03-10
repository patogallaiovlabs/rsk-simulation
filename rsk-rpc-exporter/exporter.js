const express = require('express');
const { Registry, Gauge, collectDefaultMetrics } = require('prom-client');
const axios = require('axios');

const app = express();
const port = process.env.PORT || 9090;
const rpcUrls = (process.env.RPC_URLS || 'http://rskj-miner1:4444').split(',');

const register = new Registry();
collectDefaultMetrics({ register });

const pendingTransactions = new Gauge({
    name: 'rsk_txpool_pending_transactions',
    help: 'Number of pending transactions in the mempool',
    labelNames: ['node'],
});

register.registerMetric(pendingTransactions);

async function updateMetrics() {
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
                // RSKj txpool_status returns { pending: "0x...", queued: "0x..." }
                const pending = parseInt(response.data.result.pending, 16);
                pendingTransactions.set({ node: nodeName }, pending);
            } else {
                // Fallback to eth_getBlockTransactionCount if txpool_status is not allowed
                const fallbackRes = await axios.post(url, {
                    jsonrpc: '2.0',
                    method: 'eth_getBlockTransactionCount',
                    params: ['pending'],
                    id: 1,
                }, { timeout: 2000 });

                if (fallbackRes.data && fallbackRes.data.result) {
                    const pending = parseInt(fallbackRes.data.result, 16);
                    pendingTransactions.set({ node: nodeName }, pending);
                }
            }
        } catch (error) {
            console.error(`Error fetching metrics from ${url}: ${error.message}`);
        }
    }
}

// Update metrics periodically
setInterval(updateMetrics, 2000);

app.get('/metrics', async (req, res) => {
    try {
        res.set('Content-Type', register.contentType);
        res.end(await register.metrics());
    } catch (ex) {
        res.status(500).end(ex);
    }
});

app.listen(port, '0.0.0.0', () => {
    console.log(`RSK RPC Exporter listening on port ${port}`);
    console.log(`Scraping nodes: ${rpcUrls.join(', ')}`);
});
