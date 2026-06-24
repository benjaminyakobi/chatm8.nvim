# chatm8.nvim
A NeoVim AI Chat Plugin for exploring how AI understands and helps with code.

## Installation
Using [lazy.nvim](https://github.com/folke/lazy.nvim)

Basic setup (currently `openai` & `gemini` only):
```lua
  {
    'benjaminyakobi/chatm8.nvim',
    config = function()
      require('chat').setup {
        provider = 'openai',
        providers = {
          gemini = {
            api_key = '<GEMINI_API_KEY>',
          },
          openai = {
            api_key = '<OPENAI_API_KEY>',
            models = {'MODEL 1', 'MODEL 2', 'ETC.'}
          },

        },
      }
    end,
  },
```
Local dev setup:

```lua
  {
    'benjaminyakobi/chatm8.nvim',
    dir = '<CLONE_BASE_DIR>/chatm8.nvim/',
    config = function()
      require('chat').setup {
        dev = true,
        provider = 'openai',
        providers = {
          gemini = {
            api_key = '<GEMINI_API_KEY>',
          },
          openai = {
            api_key = '<OPENAI_API_KEY>',
            models = {'MODEL 1', 'MODEL 2', 'ETC.'}
          },
        },
      }
    end,
  },
```

## How it works
<Leader>8i: Inline Implementation
  1. [Visual Mode] Select text (either code snippets or natural language instructions).
  2. Press <Leader>8i to automatically complete the implementation or transform 
     the selection directly in the current buffer.

<Leader>8p: Single Prompt (Custom on Selection)
  1. [Visual Mode] Select text and press `<Leader>8p` to open a single prompt window.
  2. [Prompt Customization] Write a custom prompt template for this request.
  3. [Replace Selection] The model response replaces the selected text in the buffer.

<Leader>8c: Persistent Chat
  1. [Normal/Visual Mode] Press `<Leader>8c` to toggle a persistent chat window
     in a split view.
  2. [Chat Window] Maintain a continuous, multi-turn conversation with the model
     that persists across different files and buffers.
  2.0. [Session] This session is ephemeral: it will be deleted when you quit Neovim.
    2.1. [Layout] Two windows will open:
         - Upper window: conversation history (read-only).
         - Lower window: prompt input.
    2.2. [Navigation] Press <C-s> in Normal or Visual mode to switch between the
         history window and the prompt window.

<Leader>8s: LLM Provider Selection
  1. Press `<Leader>8s` to open a provider selection menu.
  2. Choose the active LLM provider (e.g., OpenAI / Gemini, depending on your setup).
  3. [Scope] The selected provider becomes the default for all subsequent Leader-8 features
     (e.g., `<Leader>8i` inline implementation, `<Leader>8p` single prompt, and `<Leader>8c` chat).
  4. [Persistence] The selection is saved for the current Neovim session.

