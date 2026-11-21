/**
 * HMAC-SHA256 check of a backend request.
 *
 * @feature US-POW-05, US-MOD-01, F-26
 */
import {
  MAX_CLOCK_SKEW_SECONDS,
  SIGNATURE_HEADER,
  SIGNATURE_PREFIX,
  TIMESTAMP_HEADER,
} from './constants.ts'

const hexByte = /^[0-9a-f]{2}$/
const digits = /^\d+$/

function hexToBytes(hex: string): Uint8Array<ArrayBuffer> | null {
  const pairs = hex.match(/.{2}/g) ?? []
  const valid = hex.length > 0 && hex.length % 2 === 0 && pairs.every((p) => hexByte.test(p))
  return valid ? Uint8Array.from(pairs, (p) => Number.parseInt(p, 16)) : null
}

function isFresh(timestamp: string, nowSeconds: number): boolean {
  return (
    digits.test(timestamp) && Math.abs(nowSeconds - Number(timestamp)) <= MAX_CLOCK_SKEW_SECONDS
  )
}

/**
 * Whether the request carries a fresh signature of its body made with the shared secret.
 *
 * @param headers - Request headers with the timestamp and signature.
 * @param body - The raw request body.
 * @param secret - Secret shared with the backend.
 * @returns True when the signature is valid and the timestamp is within the allowed skew.
 * @feature US-POW-05, US-MOD-01, F-26
 */
export async function hasValidSignature(
  headers: Headers,
  body: string,
  secret: string,
): Promise<boolean> {
  const timestamp = headers.get(TIMESTAMP_HEADER) ?? ''
  const header = headers.get(SIGNATURE_HEADER) ?? ''
  const signature = header.startsWith(SIGNATURE_PREFIX)
    ? hexToBytes(header.slice(SIGNATURE_PREFIX.length))
    : null
  const nowSeconds = Math.floor(Date.now() / 1000)
  if (signature === null || secret === '' || !isFresh(timestamp, nowSeconds)) {
    return false
  }
  const encoder = new TextEncoder()
  const key = await crypto.subtle.importKey(
    'raw',
    encoder.encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['verify'],
  )
  // verify() compares in constant time.
  return crypto.subtle.verify('HMAC', key, signature, encoder.encode(`${timestamp}.${body}`))
}
