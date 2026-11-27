import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanup, render } from '@testing-library/react'

// ChatRenderer.tsx imports auth/stream modules at load time; stub them so the
// component module can be imported on its own.
vi.mock('../auth/CognitoProvider', () => ({ useAuth: () => ({}) }))
vi.mock('../services/agentStream', () => ({ streamAgent: vi.fn() }))

import { MarkdownView } from './ChatRenderer'

afterEach(cleanup)

function renderMd(text: string) {
  return render(<MarkdownView className="md" text={text} />).container.querySelector('.md') as HTMLElement
}

describe('MarkdownView', () => {
  it('renders normal Markdown', () => {
    const root = renderMd('# Title\n\nSome **bold** and `code`.\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n```py\nprint(1)\n```')
    expect(root.querySelector('h1')?.textContent).toBe('Title')
    expect(root.querySelector('strong')?.textContent).toBe('bold')
    expect(root.querySelector('table td')?.textContent).toBe('1')
    expect(root.querySelector('pre code')?.className).toContain('language-py')
  })

  it('removes scripts, event handlers, javascript: URLs, iframes, forms and styles', () => {
    const root = renderMd(
      [
        '<script>window.__xss = 1</script>',
        '<img src="x" onerror="window.__xss = 2">',
        '[click](javascript:window.__xss=3)',
        '<iframe src="https://evil.example"></iframe>',
        '<form action="https://evil.example"><input name="p"></form>',
        '<p style="color:red">styled</p>',
      ].join('\n\n'),
    )
    expect(root.querySelector('script, iframe, form, input')).toBeNull()
    expect(root.querySelector('[onerror]')).toBeNull()
    expect(root.querySelector('[style]')).toBeNull()
    expect(root.querySelector('a[href^="javascript:"]')).toBeNull()
    expect((window as unknown as { __xss?: number }).__xss).toBeUndefined()
  })

  it('opens links in a new tab without an opener', () => {
    const a = renderMd('[docs](https://docs.aws.amazon.com/)').querySelector('a')
    expect(a?.getAttribute('href')).toBe('https://docs.aws.amazon.com/')
    expect(a?.getAttribute('target')).toBe('_blank')
    expect(a?.getAttribute('rel')).toBe('noopener noreferrer')
  })

  it('renders text containing HTML-like characters as text', () => {
    const root = renderMd('a < b && c > d')
    expect(root.textContent).toContain('a < b && c > d')
  })

  it('renders nothing for empty text', () => {
    expect(renderMd('').childNodes.length).toBe(0)
  })
})
