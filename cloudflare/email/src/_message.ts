/**
 * Validation of the request body and composition of the moderator e-mail.
 *
 * @feature US-POW-05, US-MOD-01, F-26
 */
import copy from '../copy/pl.json' with { type: 'json' }
import { CASE_PATTERN, CASE_PLACEHOLDER, LIST_SEPARATOR } from './constants.ts'
import type { EmailMessageBuilder, Env } from './ports.ts'

type Notice = { to: string; caseNumber: string; panelUrl: string }

function list(value: string): string[] {
  return value
    .split(LIST_SEPARATOR)
    .map((item) => item.trim().toLowerCase())
    .filter(Boolean)
}

function parseJson(body: string): unknown {
  try {
    return JSON.parse(body)
  } catch {
    return null
  }
}

function isPanelLink(value: string, env: Env): boolean {
  if (!URL.canParse(value)) {
    return false
  }
  const url = new URL(value)
  return url.protocol === 'https:' && list(env.PANEL_ORIGINS).includes(url.origin)
}

function parseNotice(body: string): Notice | null {
  const data = parseJson(body)
  if (typeof data !== 'object' || data === null) {
    return null
  }
  const { to, case: caseNumber, panel_url: panelUrl } = data as Record<string, unknown>
  const allStrings =
    typeof to === 'string' && typeof caseNumber === 'string' && typeof panelUrl === 'string'
  return allStrings ? { to, caseNumber, panelUrl } : null
}

/**
 * Build the e-mail for a backend request, or null when the request must be refused.
 * The address must be on the verified list, the case number short and plain, and the
 * link must point to the moderator panel.
 *
 * @param body - The raw JSON body: `{"to", "case", "panel_url"}`.
 * @param env - The Worker's environment with the address list and panel origins.
 * @returns The message to send, or null for a request that gets 400.
 * @feature US-POW-05, US-MOD-01, F-26
 */
export function composeMessage(body: string, env: Env): EmailMessageBuilder | null {
  const notice = parseNotice(body)
  const isValid =
    notice !== null &&
    list(env.MODERATOR_ADDRESSES).includes(notice.to.trim().toLowerCase()) &&
    CASE_PATTERN.test(notice.caseNumber) &&
    isPanelLink(notice.panelUrl, env)
  if (!isValid) {
    return null
  }
  const subject = copy.notifications.kind.case_assigned.replace(CASE_PLACEHOLDER, notice.caseNumber)
  return {
    from: env.FROM_ADDRESS,
    to: notice.to.trim(),
    subject,
    text: `${subject}\n\n${notice.panelUrl}`,
  }
}
