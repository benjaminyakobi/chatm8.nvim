# chat.nvim
NeoVim AI Plugin inspired by ThePrimeagen/99

## Installation
Using [lazy.nvim](https://github.com/folke/lazy.nvim)

Basic setup (currently `gemini` only):
```lua
  {
    'benjaminyakobi/chat.nvim',
    config = function()
      require('chat').setup({ api_key = 'gemini-api-key' })
    end,
  },
```
Local dev setup:

```lua
  {
    'benjaminyakobi/chat.nvim',
    config = function()
      require('chat').setup({ dev = true, api_key = 'gemini-api-key' })
    end,
  },
```
