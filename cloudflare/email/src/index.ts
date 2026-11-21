/**
 * Cloudflare Worker that e-mails moderators about a new or updated case. The backend
 * calls it over HTTPS with a signed request; the `send_email` binding delivers the message
 * to an address verified in Email Routing (ADR-14, ADR-29).
 *
 * @feature US-POW-05, US-MOD-01, F-26
 */

import { composeMessage } from './_message.ts'
import { hasValidSignature } from './_signature.ts'
import { MAX_BODY_LENGTH } from './constants.ts'
import type { Env } from './ports.ts'

async function deliver(body: string, env: Env): Promise<Response> {
  const message = composeMessage(body, env)
  if (message === null) {
    return new Response(null, { status: 400 })
  }
  try {
    await env.SEND_EMAIL.send(message)
  } catch (error) {
    // Only the error code is logged: the message may contain the recipient address.
    const code = error instanceof Error && 'code' in error ? String(error.code) : 'unknown'
    console.error('send_email failed', code)
    return new Response(null, { status: 502 })
  }
  return new Response(null, { status: 202 })
}

/**
 * The Worker: `POST /` with `{"to", "case", "panel_url"}` signed by the backend.
 * Answers 202 (sent), 400 (address off the list or bad body), 401 (signature),
 * 405 (method) or 502 (Cloudflare refused the send).
 *
 * @feature US-POW-05, US-MOD-01, F-26
 */
export default {
  /**
   * Handle one backend request.
   *
   * @param request - The incoming request.
   * @param env - Bindings, secrets and variables.
   * @returns The status-only response.
   * @feature US-POW-05, US-MOD-01, F-26
   */
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method !== 'POST') {
      return new Response(null, { status: 405, headers: { allow: 'POST' } })
    }
    const body = await request.text()
    // Checked before the HMAC so an oversized body costs no hashing.
    if (body.length > MAX_BODY_LENGTH) {
      return new Response(null, { status: 400 })
    }
    const signed = await hasValidSignature(request.headers, body, env.SIGNING_SECRET)
    return signed ? deliver(body, env) : new Response(null, { status: 401 })
  },
}
