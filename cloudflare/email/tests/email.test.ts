import assert from 'node:assert/strict'
import { createHmac } from 'node:crypto'
import { test } from 'node:test'
import {
  MAX_BODY_LENGTH,
  MAX_CLOCK_SKEW_SECONDS,
  SIGNATURE_HEADER,
  SIGNATURE_PREFIX,
  TIMESTAMP_HEADER,
} from '../src/constants.ts'
import worker from '../src/index.ts'
import type { EmailMessageBuilder, Env } from '../src/ports.ts'

const secret = 'test-secret'
const moderator = 'moderator@example.com'
const body = {
  to: moderator,
  case: 'S-42',
  panel_url: 'https://meritum.gburek.app/panel/sprawy/S-42',
}

function fakeEnv(): { env: Env; sent: EmailMessageBuilder[] } {
  const sent: EmailMessageBuilder[] = []
  const env: Env = {
    SEND_EMAIL: {
      send: (message) => {
        sent.push(message)
        return Promise.resolve({ messageId: 'm-1' })
      },
    },
    SIGNING_SECRET: secret,
    MODERATOR_ADDRESSES: ` ${moderator.toUpperCase()} , other@example.com`,
    FROM_ADDRESS: 'meritum@gburek.app',
    PANEL_ORIGINS: 'https://meritum.gburek.app,https://meritum-dev.gburek.app',
  }
  return { env, sent }
}

function signedRequest(payload: unknown, options: { key?: string; at?: number } = {}): Request {
  const text = JSON.stringify(payload)
  const timestamp = String(options.at ?? Math.floor(Date.now() / 1000))
  const signature = createHmac('sha256', options.key ?? secret)
    .update(`${timestamp}.${text}`)
    .digest('hex')
  return new Request('https://email.example/', {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      [TIMESTAMP_HEADER]: timestamp,
      [SIGNATURE_HEADER]: `${SIGNATURE_PREFIX}${signature}`,
    },
    body: text,
  })
}

test('a signed request to a verified moderator sends one e-mail and answers 202', async () => {
  const { env, sent } = fakeEnv()
  const response = await worker.fetch(signedRequest(body), env)
  assert.equal(response.status, 202)
  assert.equal(sent.length, 1)
  assert.deepEqual(sent[0], {
    from: 'meritum@gburek.app',
    to: moderator,
    subject: 'Nowa albo zaktualizowana sprawa S-42.',
    text: `Nowa albo zaktualizowana sprawa S-42.\n\n${body.panel_url}`,
  })
})

test('an address outside the verified list gets 400 and nothing is sent', async () => {
  const { env, sent } = fakeEnv()
  const response = await worker.fetch(signedRequest({ ...body, to: 'stranger@example.com' }), env)
  assert.equal(response.status, 400)
  assert.equal(sent.length, 0)
})

test('a request without a valid signature gets 401 and nothing is sent', async () => {
  const { env, sent } = fakeEnv()
  const unsigned = new Request('https://email.example/', {
    method: 'POST',
    body: JSON.stringify(body),
  })
  assert.equal((await worker.fetch(unsigned, env)).status, 401)
  assert.equal((await worker.fetch(signedRequest(body, { key: 'wrong' }), env)).status, 401)
  assert.equal(sent.length, 0)
})

test('a timestamp outside the allowed skew gets 401', async () => {
  const { env, sent } = fakeEnv()
  const now = Math.floor(Date.now() / 1000)
  const times = [now - MAX_CLOCK_SKEW_SECONDS - 1, now + MAX_CLOCK_SKEW_SECONDS + 1]
  const responses = await Promise.all(
    times.map((at) => worker.fetch(signedRequest(body, { at }), env)),
  )
  assert.deepEqual(
    responses.map((r) => r.status),
    [401, 401],
  )
  assert.equal(sent.length, 0)
})

test('an empty signing secret refuses every request', async () => {
  const { env, sent } = fakeEnv()
  env.SIGNING_SECRET = ''
  assert.equal((await worker.fetch(signedRequest(body, { key: '' }), env)).status, 401)
  assert.equal(sent.length, 0)
})

test('a panel link outside the panel origins gets 400', async () => {
  const { env, sent } = fakeEnv()
  const links = ['https://evil.example/panel', 'http://meritum.gburek.app/panel', 'nie-link']
  const responses = await Promise.all(
    links.map((panelUrl) => worker.fetch(signedRequest({ ...body, panel_url: panelUrl }), env)),
  )
  assert.deepEqual(
    responses.map((r) => r.status),
    [400, 400, 400],
  )
  assert.equal(sent.length, 0)
})

test('a malformed body or case number gets 400', async () => {
  const { env, sent } = fakeEnv()
  const payloads = [
    { ...body, padding: 'x'.repeat(MAX_BODY_LENGTH) },
    'tekst',
    { ...body, case: 'S 42\nBcc: x@example.com' },
    { to: moderator },
  ]
  const responses = await Promise.all(payloads.map((p) => worker.fetch(signedRequest(p), env)))
  assert.deepEqual(
    responses.map((r) => r.status),
    [400, 400, 400, 400],
  )
  assert.equal(sent.length, 0)
})

test('a method other than POST gets 405', async () => {
  const { env } = fakeEnv()
  const response = await worker.fetch(new Request('https://email.example/'), env)
  assert.equal(response.status, 405)
})

test('a failed send answers 502', async () => {
  const { env } = fakeEnv()
  env.SEND_EMAIL = { send: () => Promise.reject(new Error('E_DELIVERY_FAILED')) }
  assert.equal((await worker.fetch(signedRequest(body), env)).status, 502)
})
