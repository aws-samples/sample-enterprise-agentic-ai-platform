import { useState } from 'react'

// Categorized example prompts that seed a Design_Session.
//
// Content is mirrored verbatim from the standalone Agent Builder Studio
// (`platform/demo-ui/standalone/agent-builder-studio-ui/src/App.tsx`
// `SAMPLE_PROMPTS`) so the Console reaches parity with the Studio.
//
// _Requirements: 3.1, 3.2, 3.3_
// "About EAP" — learn-the-platform prompts, kept SEPARATE from the
// build-an-agent Sample Prompts below so the two intents don't visually mix.
export const ABOUT_PROMPTS: Record<string, string[]> = {
  'Get Started': [
    'How do you work, and what kinds of agents can you build for me?',
    'What is EAP and what is its core philosophy?',
    'Walk me through deploying my first agent.',
  ],
  'Platform (Technical)': [
    'Explain the base image and how observability and protocols get injected into every agent.',
    'Walk me through the CI/CD pipeline — from a YAML push to a running AgentCore runtime.',
    "Explain EAP's declarative philosophy: YAML in, infrastructure out.",
    'How does the platform manage state — desired vs. provisioning vs. operational?',
    'What is Agent School and how does the agent lifecycle work?',
  ],
}

export const SAMPLE_PROMPTS: Record<string, string[]> = {
  Support: [
    'I need a customer support agent that answers questions from our knowledge base',
    'Build an agent that handles IT helpdesk tickets',
  ],
  Research: [
    'Create an agent that researches topics and writes summaries',
    'I want a research assistant that searches multiple sources',
  ],
  Workflow: [
    'Build a document review pipeline with multiple reviewers',
    'Create an approval workflow agent for expense reports',
  ],
  'Multi-Agent': [
    'Design a team of agents that collaborate on code reviews',
    'I need a supervisor agent that delegates to specialist agents',
    'Build a research assistant with specialized agents for internal KB search and external web search, using RRF ranking to merge results — supports follow-up questions at high query volume',
  ],
}

/** Ordered category tabs (Req 3.1). */
export const SAMPLE_PROMPT_CATEGORIES = Object.keys(SAMPLE_PROMPTS)

export interface SamplePromptsProps {
  /**
   * Invoked with the selected prompt text when a user picks a prompt.
   * The parent (BuildWorkspace) wires this to populate the active-session
   * input and send it as a message (Req 3.3).
   */
  onSelect: (prompt: string) => void
  /** When true, prompt selection is disabled (e.g. user not authenticated). */
  disabled?: boolean
}

/**
 * Categorized Sample_Prompts with a tabbed category selector.
 *
 * - Displays prompts grouped into Support, Research, Workflow, and Multi-Agent
 *   (Req 3.1).
 * - Selecting a category shows only that category's prompts (Req 3.2).
 * - Selecting a prompt invokes {@link SamplePromptsProps.onSelect} with the
 *   prompt text so the parent can populate the input and send it (Req 3.3).
 */
export function SamplePrompts({ onSelect, disabled = false }: SamplePromptsProps) {
  const [activeCategory, setActiveCategory] = useState<string>(SAMPLE_PROMPT_CATEGORIES[0])

  const prompts = SAMPLE_PROMPTS[activeCategory] ?? []

  return (
    <div className="space-y-2">
      {/* About EAP — learn-the-platform prompts, separated from the
          build-an-agent Sample Prompts below so the two intents don't mix. */}
      <div className="space-y-2">
        <h3 className="text-xs font-medium text-brand-400 uppercase tracking-wider px-1">
          Learn about EAP
        </h3>
        {Object.entries(ABOUT_PROMPTS).map(([group, groupPrompts]) => (
          <div key={group} className="space-y-1">
            <p className="text-[10px] font-medium text-brand-500 uppercase tracking-wider px-1">
              {group}
            </p>
            {groupPrompts.map((prompt) => (
              <button
                key={prompt}
                type="button"
                disabled={disabled}
                onClick={() => onSelect(prompt)}
                title={disabled ? 'Sign in to use prompts' : prompt}
                className={`w-full text-left text-xs rounded px-2 py-1.5 transition-colors ${
                  disabled
                    ? 'bg-gray-800 text-gray-500 cursor-not-allowed'
                    : 'bg-gray-700 text-gray-300 hover:bg-gray-600 cursor-pointer'
                }`}
              >
                {prompt}
              </button>
            ))}
          </div>
        ))}
      </div>

      {/* Divider between "learn" (above) and "build" (below). */}
      <div className="border-t border-gray-700 !mt-3 pt-3" />

      <h3 className="text-xs font-medium text-brand-400 uppercase tracking-wider px-1">
        Build an Agent
      </h3>

      {/* Category tabs (Req 3.1, 3.2) */}
      <div className="flex flex-wrap gap-1" role="tablist" aria-label="Sample prompt categories">
        {SAMPLE_PROMPT_CATEGORIES.map((category) => {
          const isActive = category === activeCategory
          return (
            <button
              key={category}
              type="button"
              role="tab"
              aria-selected={isActive}
              onClick={() => setActiveCategory(category)}
              className={`text-xs px-2 py-1 rounded transition-colors ${
                isActive
                  ? 'bg-blue-600 text-white'
                  : 'bg-gray-700 text-gray-300 hover:bg-gray-600'
              }`}
            >
              {category}
            </button>
          )
        })}
      </div>

      {/* Prompts for the active category (Req 3.2, 3.3) */}
      <div className="space-y-1" role="tabpanel" aria-label={`${activeCategory} prompts`}>
        {prompts.map((prompt) => (
          <button
            key={prompt}
            type="button"
            disabled={disabled}
            onClick={() => onSelect(prompt)}
            title={disabled ? 'Sign in to use sample prompts' : prompt}
            className={`w-full text-left text-xs rounded px-2 py-1.5 transition-colors ${
              disabled
                ? 'bg-gray-800 text-gray-500 cursor-not-allowed'
                : 'bg-gray-700 text-gray-300 hover:bg-gray-600 cursor-pointer'
            }`}
          >
            {prompt}
          </button>
        ))}
      </div>
    </div>
  )
}
