import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { CognitoProvider } from './auth/CognitoProvider'
import { BUProvider } from './hooks/useBU'
import { AppShell } from './components/AppShell'
import { AppsWorkspace } from './workspaces/AppsWorkspace'
import { ExamplesWorkspace } from './workspaces/ExamplesWorkspace'
import { BuildWorkspace } from './workspaces/BuildWorkspace'
import { DataWorkspace } from './workspaces/DataWorkspace'
import { QualityWorkspace } from './workspaces/QualityWorkspace'
import { AdminWorkspace } from './workspaces/AdminWorkspace'
import { GovernanceWorkspace } from './workspaces/GovernanceWorkspace'
import { PlatformWorkspace } from './workspaces/PlatformWorkspace'
import { ObservabilityWorkspace } from './workspaces/ObservabilityWorkspace'

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 30_000,
      retry: 3,
      refetchOnWindowFocus: false,
    },
  },
})

export default function App() {
  return (
    <QueryClientProvider client={queryClient}>
      <CognitoProvider>
        <BUProvider>
          <BrowserRouter>
            <Routes>
              <Route element={<AppShell />}>
                <Route path="/apps" element={<AppsWorkspace />} />
                <Route path="/examples" element={<ExamplesWorkspace />} />
                <Route path="/build" element={<BuildWorkspace />} />
                <Route path="/data" element={<DataWorkspace />} />
                <Route path="/quality" element={<QualityWorkspace />} />
                <Route path="/admin" element={<AdminWorkspace />} />
                <Route path="/governance" element={<GovernanceWorkspace />} />
                <Route path="/platform" element={<PlatformWorkspace />} />
                <Route path="/observability" element={<ObservabilityWorkspace />} />
                <Route path="/auth/callback" element={<div>Authenticating...</div>} />
                <Route path="/" element={<Navigate to="/apps" replace />} />
                <Route path="*" element={<Navigate to="/apps" replace />} />
              </Route>
            </Routes>
          </BrowserRouter>
        </BUProvider>
      </CognitoProvider>
    </QueryClientProvider>
  )
}
