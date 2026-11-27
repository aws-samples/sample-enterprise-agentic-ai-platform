import React, { createContext, useContext, useState, useEffect, useCallback } from 'react'
import { useAuth } from '../auth/CognitoProvider'

export interface BUContextValue {
  selectedBU: string
  availableBUs: string[]
  setSelectedBU: (bu: string) => void
  domain: string // Resolved domain name for DynamoDB queries
}

const BUContext = createContext<BUContextValue>({
  selectedBU: '',
  availableBUs: [],
  setSelectedBU: () => {},
  domain: '',
})

export function useBU(): BUContextValue {
  return useContext(BUContext)
}

/**
 * Extract BU identifiers from Cognito groups.
 * Groups prefixed with "bu:" are treated as BU memberships.
 */
export function extractBUsFromGroups(groups: string[]): string[] {
  return groups
    .filter((g) => g.startsWith('bu:'))
    .map((g) => g.slice(3))
}

interface BUProviderProps {
  children: React.ReactNode
}

export function BUProvider({ children }: BUProviderProps) {
  const { groups } = useAuth()
  const availableBUs = extractBUsFromGroups(groups)

  const [selectedBU, setSelectedBUState] = useState<string>(() => {
    const stored = sessionStorage.getItem('console_selected_bu')
    if (stored && availableBUs.includes(stored)) return stored
    return availableBUs[0] || ''
  })

  // Update selection when available BUs change (e.g., on login)
  useEffect(() => {
    if (availableBUs.length > 0 && !availableBUs.includes(selectedBU)) {
      setSelectedBUState(availableBUs[0])
    } else if (availableBUs.length > 0 && !selectedBU) {
      setSelectedBUState(availableBUs[0])
    }
  }, [availableBUs, selectedBU])

  const setSelectedBU = useCallback((bu: string) => {
    setSelectedBUState(bu)
    sessionStorage.setItem('console_selected_bu', bu)
  }, [])

  // Domain is the BU identifier used as DynamoDB partition key prefix
  const domain = selectedBU ? `team-${selectedBU}` : ''

  const value: BUContextValue = {
    selectedBU,
    availableBUs,
    setSelectedBU,
    domain,
  }

  return React.createElement(BUContext.Provider, { value }, children)
}

export { BUContext }
