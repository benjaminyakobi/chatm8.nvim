# chat.nvim
NeoVim AI Chat Plugin

## Installation
Using [lazy.nvim](https://github.com/folke/lazy.nvim)

Basic setup (currently `gemini` only):
```lua
  {
    'benjaminyakobi/chat.nvim',
    config = function()
      require('chat').setup {
        provider = 'gemini',
        providers = {
          gemini = {
            api_key = '<GEMINI_API_KEY>',
          },
        },
      }
    end,
  },
```
Local dev setup:

```lua
  {
    'benjaminyakobi/chat.nvim',
    dir = '<CLONE_BASE_DIR>/chat.nvim/',
    config = function()
      require('chat').setup {
        dev = true,
        provider = 'gemini',
        providers = {
          gemini = {
            api_key = '<GEMINI_API_KEY>',
          },
        },
      }
    end,
  },
```

## How it works
<Leader>8p: Prompt Interface
  1. [Visual Mode] Select text (either code snippets or natural language
     instructions) and press <Leader>8p to open the prompt window.
  2. [Layout] Two windows will open:
     - Upper window: conversation history (read-only).
     - Lower window: prompt input.
  3. [Navigation] Press <C-s> in Normal or Visual mode to switch between the
     history window and the prompt window.

<Leader>8i: Inline Implementation
  1. [Visual Mode] Select text (either code snippets or natural language instructions).
  2. Press <Leader>8i to automatically complete the implementation or transform
     the selection directly in the current buffer.

<Leader>8c: Persistent Chat
  1. [Normal/Visual Mode] Press `<Leader>8c` to toggle a persistent chat window
     in a split view.
  2. [Chat Window] Maintain a continuous, multi-turn conversation with the model 
     that persists across different files and buffers.

