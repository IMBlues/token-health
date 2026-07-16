#!/usr/bin/env node
let input = ''
process.stdin.setEncoding('utf8')
process.stdin.on('data', (chunk) => {
  input += chunk
  if (input.split('\n').filter(Boolean).length >= 3) {
    process.stdout.write(JSON.stringify({ method: 'remoteControl/status/changed', params: {} }) + '\n')
    process.stdout.write(JSON.stringify({ id: 999, result: { ignored: true } }) + '\n')
    process.stdout.write(JSON.stringify({ id: 1, result: { rateLimits: { limitId: 'codex', primary: { usedPercent: 21, windowDurationMins: 300, resetsAt: 1783665814 }, secondary: { usedPercent: 8, windowDurationMins: 10080, resetsAt: 1784252614 }, planType: 'plus' } } }) + '\n')
  }
})
