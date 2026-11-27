import { useEffect, useRef } from 'react'

/**
 * Hook for configurable interval-based data refresh.
 * Calls the provided callback at the specified interval.
 * Automatically cleans up on unmount.
 *
 * Usage:
 *   usePolling(() => refetch(), 30_000) // Refresh every 30s
 *   usePolling(() => refetch(), 10_000, { enabled: isActive }) // Conditional polling
 */
export function usePolling(
  callback: () => void,
  intervalMs: number,
  options?: { enabled?: boolean }
) {
  const savedCallback = useRef(callback)
  const enabled = options?.enabled ?? true

  // Remember the latest callback
  useEffect(() => {
    savedCallback.current = callback
  }, [callback])

  useEffect(() => {
    if (!enabled || intervalMs <= 0) return

    const tick = () => savedCallback.current()
    const id = setInterval(tick, intervalMs)

    return () => clearInterval(id)
  }, [intervalMs, enabled])
}
