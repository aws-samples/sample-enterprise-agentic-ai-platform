import { useBU } from '../hooks/useBU'

export function BUSelector() {
  const { selectedBU, availableBUs, setSelectedBU } = useBU()

  if (availableBUs.length === 0) {
    return (
      <span className="text-sm text-white/70 bg-brand-700 rounded px-2 py-1 border border-brand-500" aria-label="Business unit">
        BU-1
      </span>
    )
  }

  return (
    <label className="flex items-center gap-2 text-sm">
      <span className="text-brand-200 sr-only">Business Unit</span>
      <select
        value={selectedBU}
        onChange={(e) => setSelectedBU(e.target.value)}
        className="bg-brand-700 text-white text-sm rounded px-2 py-1 border border-brand-500 focus:outline-none focus:ring-2 focus:ring-brand-300"
        aria-label="Select business unit"
      >
        {availableBUs.map((bu) => (
          <option key={bu} value={bu}>
            {bu}
          </option>
        ))}
      </select>
    </label>
  )
}
