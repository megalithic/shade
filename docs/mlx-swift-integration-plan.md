# MLX Swift Integration Plan for Shade

> **Status**: Proposal
> **Created**: 2026-01-09
> **Epic**: shade-cgn (Image capture intelligence)

## Executive Summary

Replace the planned Ollama HTTP client approach with **native MLX Swift** integration for on-device LLM inference. This provides:

- **Zero external dependencies** - No Ollama server to manage
- **Native Swift API** - Direct integration, no HTTP overhead
- **Apple Silicon optimized** - Metal GPU acceleration, unified memory
- **Single process** - Everything runs in Shade

---

## Current State

### Existing Epic: shade-cgn
```
shade-cgn: Image capture intelligence: OCR + AI summarization pipeline

Children:
  ✅ shade-cgn.1: Setup Ollama with optimal models for M2 Max [closed]
  🔄 shade-cgn.2: Implement VisionKit OCR in Shade (Swift) [open]
  🔄 shade-cgn.3: Implement Ollama client in Shade for summarization [open]
  🔄 shade-cgn.4: Wire up OCR+AI pipeline in image capture flow [open]
  🔄 shade-cgn.5: Add manual OCR/summarize commands via ShadeServer RPC [open]
```

### Proposed Change

Replace **shade-cgn.3** (Ollama client) with **MLX Swift native integration**.

| Approach | Pros | Cons |
|----------|------|------|
| **Ollama (HTTP)** | Already running, multi-model, battle-tested | External process, HTTP overhead, cold start latency |
| **MLX Swift (Native)** | Single process, Swift-native, Metal-optimized, no dependencies | New integration work, model management in-app |

**Recommendation**: MLX Swift - fits Shade's philosophy of native, self-contained tools.

---

## Model Selection for M2 Max (64GB unified memory)

### Design Philosophy: Quality Over Speed

Notes are **permanent artifacts**. A 2-second summary vs a 0.8-second summary is irrelevant
when the note will be referenced for years. We optimize for **precision and accuracy**.

With 64GB unified memory, we have headroom for larger, higher-quality models.

### Primary Use Cases

| Use Case | Description | Model Requirements |
|----------|-------------|-------------------|
| **OCR Summarization** | Summarize extracted text from screenshots | Instruction-following, concise output |
| **Capture Context** | Understand URL + selection + app context | General comprehension, short prompts |
| **Note Enrichment** | Add tags, categories, suggested titles | Classification, labeling |
| **VLM (Future)** | Direct image understanding without OCR step | Vision-language model |

### Recommended Models (Quality-First)

#### Default: High Quality
| Model | Size | VRAM | Speed | Quality |
|-------|------|------|-------|---------|
| **Qwen3-8B-Instruct-4bit** | ~4.3 GB | ~8 GB | ~50 tok/s | ★★★★½ |
| **Mistral-7B-Instruct-v0.3-4bit** | ~3.8 GB | ~6 GB | ~60 tok/s | ★★★★ |

#### Premium: Maximum Quality (64GB allows this!)
| Model | Size | VRAM | Speed | Quality |
|-------|------|------|-------|---------|
| **Qwen3-8B-Instruct-bf16** | ~16 GB | ~18 GB | ~30 tok/s | ★★★★★ |
| **Qwen3-14B-Instruct-4bit** | ~7.5 GB | ~12 GB | ~35 tok/s | ★★★★★ |

#### Fallback: Fast (when speed needed)
| Model | Size | VRAM | Speed | Quality |
|-------|------|------|-------|---------|
| **Llama-3.2-3B-Instruct-4bit** | ~0.8 GB | ~2 GB | ~120 tok/s | ★★★½ |
| **Qwen3-4B-Instruct-4bit** | ~2.5 GB | ~4 GB | ~80 tok/s | ★★★★ |

#### Vision-Language (Future)
| Model | Size | VRAM | Best For |
|-------|------|------|----------|
| **Qwen2-VL-7B-Instruct-4bit** | ~4 GB | ~6 GB | Direct image understanding |
| **Gemma-3-4B-it-4bit** | ~3.2 GB | ~5 GB | Images + text |

### Recommendation for Shade

**Default**: `mlx-community/Qwen3-8B-Instruct-4bit`
- Best quality-to-resource ratio
- Excellent instruction following
- ~50 tok/s is plenty fast for note enrichment
- 4.3 GB is negligible on 64GB system

**Quality option**: `mlx-community/Qwen3-8B-Instruct-bf16`
- Full precision (no quantization artifacts)
- ~16 GB memory footprint
- Best possible summarization quality
- Use when accuracy is paramount

**Fast fallback**: `mlx-community/Llama-3.2-3B-Instruct-4bit`
- For bulk operations or when memory constrained

---

## Architecture

### Integration Point

```
┌─────────────────────────────────────────────────────────────────┐
│                        Shade (Swift)                            │
├─────────────────────────────────────────────────────────────────┤
│  ShadeAppDelegate                                               │
│    ├── TerminalView (ghostty)                                   │
│    ├── NvimSocketManager (msgpack-rpc)                          │
│    ├── ShadeServer (RPC server on shade.sock)                   │
│    │                                                            │
│    └── NEW: MLXInferenceEngine                                  │
│            ├── ModelManager (load/unload models)                │
│            ├── TextGenerator (LLM inference)                    │
│            └── VisionProcessor (VLM inference - future)         │
├─────────────────────────────────────────────────────────────────┤
│  MLXLLM (Swift Package)                                         │
│    └── ChatSession, loadModel, generate                         │
├─────────────────────────────────────────────────────────────────┤
│  MLX (Metal-accelerated tensors)                                │
└─────────────────────────────────────────────────────────────────┘
```

### New Components

#### 1. MLXInferenceEngine.swift
```swift
import MLXLLM
import MLXLMCommon

actor MLXInferenceEngine {
    private var model: LLMModel?
    private var session: ChatSession?
    private let config: MLXConfig

    init(config: MLXConfig) {
        self.config = config
    }

    // Lazy model loading - only load when first needed
    func ensureModelLoaded() async throws {
        guard model == nil else { return }
        let modelId = config.model ?? "mlx-community/Qwen3-8B-Instruct-4bit"
        model = try await loadModel(id: modelId)
        session = ChatSession(model!)
    }

    // Summarize text (OCR output, selections, etc.)
    func summarize(_ text: String, style: SummarizationStyle = .concise) async throws -> String {
        try await ensureModelLoaded()

        let prompt = """
        Summarize the following text in 1-2 sentences. Be concise and factual.

        Text:
        \(text)

        Summary:
        """

        return try await session!.respond(to: prompt)
    }

    // Categorize/tag content
    func categorize(_ text: String, context: CaptureContext?) async throws -> [String] {
        try await ensureModelLoaded()

        let contextInfo = context.map { "Source: \($0.sourceApp), URL: \($0.url ?? "none")" } ?? ""

        let prompt = """
        Given this captured text, suggest 2-3 relevant tags (lowercase, hyphenated).
        \(contextInfo)

        Text:
        \(text)

        Tags (comma-separated):
        """

        let response = try await session!.respond(to: prompt)
        return response.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // Unload model to free memory
    func unloadModel() {
        model = nil
        session = nil
    }
}
```

#### 2. Package.swift Addition
```swift
dependencies: [
    // ... existing dependencies
    .package(url: "https://github.com/ml-explore/mlx-swift-lm/",
             .upToNextMinor(from: "2.29.1"))
],
targets: [
    .executableTarget(
        name: "shade",
        dependencies: [
            // ... existing deps
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
        ]
    )
]
```

---

## Integration with Capture Flow

### Current Flow (shade-cgn.4)
```
1. Screenshot captured
2. Image saved to assets/
3. Capture note created
4. VisionKit extracts text (OCR)
5. ??? AI summarization ???
6. Content injected into note
```

### With MLX Swift (Async Pipeline)

```
SYNCHRONOUS (instant):
┌─────────────────────────────────────────────────────────────────┐
│ 1. Screenshot captured                                          │
│ 2. Image saved to assets/                                       │
│ 3. Capture note created in nvim                                 │
│ 4. VisionKit extracts text (OCR) ← instant, native              │
│ 5. OCR text + placeholder inserted into note                    │
│    ┌──────────────────────────────────────────────────────┐     │
│    │ ## Captured Text                                      │     │
│    │ <raw OCR text here>                                   │     │
│    │                                                       │     │
│    │ ## Summary                                            │     │
│    │ <!-- shade:pending:summary -->                        │     │
│    │                                                       │     │
│    │ ## Tags                                               │     │
│    │ <!-- shade:pending:tags -->                           │     │
│    └──────────────────────────────────────────────────────┘     │
│ 6. User can continue working immediately                        │
└─────────────────────────────────────────────────────────────────┘

ASYNCHRONOUS (background):
┌─────────────────────────────────────────────────────────────────┐
│ 7. Shade kicks off async Task {                                 │
│      - MLXInferenceEngine.summarize(ocrText, context)           │
│      - MLXInferenceEngine.categorize(ocrText, context)          │
│    }                                                            │
│                                                                 │
│ 8. When complete, Shade sends nvim RPC:                         │
│    - nvim_notify("Enrichment ready", INFO)                      │
│    - Find placeholder comments in buffer                        │
│    - Replace <!-- shade:pending:summary --> with actual summary │
│    - Replace <!-- shade:pending:tags --> with #tag1 #tag2       │
│    - Optionally: virtual text, sign column indicator            │
│                                                                 │
│ 9. User sees non-blocking notification in nvim                  │
│    (floating window, statusline, or echo)                       │
└─────────────────────────────────────────────────────────────────┘
```

### Nvim Integration Details

Shade already has bidirectional msgpack-RPC with nvim. The async enrichment uses this to:

**1. Insert placeholders on capture:**
```swift
// Immediate insert after OCR
try await nvim.request(method: "nvim_buf_set_lines", params: [
    .int(bufnr),
    .int(insertLine),
    .int(insertLine),
    .bool(false),
    .array([
        .string("## Summary"),
        .string("<!-- shade:pending:summary -->"),
        .string(""),
        .string("## Tags"),
        .string("<!-- shade:pending:tags -->"),
    ])
])
```

**2. Notify user when enrichment ready:**
```swift
// Non-blocking notification
try nvim.notify(method: "nvim_echo", params: [
    .array([.array([.string("✨ Capture enrichment ready"), .string("Comment")])]),
    .bool(false),  // don't add to history
    .map([:])
])
```

**3. Replace placeholders with content:**
```swift
// Find and replace placeholder
let lines = try await nvim.request(method: "nvim_buf_get_lines", params: [...])
// Find line with <!-- shade:pending:summary -->
// Replace with actual summary
try await nvim.request(method: "nvim_buf_set_lines", params: [
    .int(bufnr),
    .int(summaryLine),
    .int(summaryLine + 1),
    .bool(false),
    .array([.string(summary)])
])
```

**4. Optional: Virtual text indicator while pending:**
```swift
// Show "⏳ Generating..." as virtual text
let nsId = try await nvim.request(method: "nvim_create_namespace", params: [.string("shade")])
try await nvim.request(method: "nvim_buf_set_extmark", params: [
    .int(bufnr),
    .int(nsId),
    .int(placeholderLine),
    .int(0),
    .map([
        "virt_text": .array([.array([.string("⏳ Generating summary..."), .string("Comment")])]),
        "virt_text_pos": .string("eol")
    ])
])
```

### RPC Commands (shade-cgn.5)

Add to ShadeServer RPC interface:

| Method | Params | Returns | Description |
|--------|--------|---------|-------------|
| `shade.summarize` | `{text: string}` | `{summary: string}` | Summarize arbitrary text |
| `shade.categorize` | `{text: string, context?: object}` | `{tags: string[]}` | Get suggested tags |
| `shade.model_status` | `{}` | `{loaded: bool, model: string, memory_mb: int}` | Check model status |
| `shade.model_unload` | `{}` | `{success: bool}` | Free model memory |

---

## Configuration

### Nix-Managed Config (Recommended)

Shade config is managed via Nix in your dotfiles, ensuring reproducible, declarative configuration.

**File**: `~/.dotfiles/home/programs/shade.nix`

```nix
{ config, pkgs, lib, ... }:
let
  shadeConfig = {
    # Window behavior
    window = {
      width = 0.5;
      height = 0.6;
      padding = 0;
      decorations = false;
    };

    # Nvim integration
    nvim = {
      socket = "~/.local/state/shade/nvim.sock";
      command = "nvim --listen ~/.local/state/shade/nvim.sock";
    };

    # LLM settings (backend: "mlx" | "ollama" | "none")
    llm = {
      enabled = true;
      backend = "mlx";  # or "ollama" for HTTP fallback
      model = "mlx-community/Qwen3-8B-Instruct-4bit";

      # Quality preset: "fast" | "balanced" | "quality" | "premium"
      preset = "quality";

      # Model overrides per preset (optional)
      models = {
        fast = "mlx-community/Llama-3.2-3B-Instruct-4bit";
        balanced = "mlx-community/Qwen3-4B-Instruct-4bit";
        quality = "mlx-community/Qwen3-8B-Instruct-4bit";
        premium = "mlx-community/Qwen3-8B-Instruct-bf16";
      };

      # Behavior
      auto_summarize = true;   # Summarize OCR text automatically
      auto_categorize = true;  # Generate tags automatically
      preload = false;         # Load model at startup (vs lazy)
      idle_timeout = 300;      # Unload after N seconds idle (0 = never)
    };

    # Capture behavior
    capture = {
      ocr_enabled = true;
      working_directory = config.home.sessionVariables.notes_home + "/captures";
    };
  };
in
{
  # Generate immutable config at ~/.config/shade/config.json
  xdg.configFile."shade/config.json" = {
    text = builtins.toJSON shadeConfig;
  };

  # Ensure shade binary is available
  home.packages = [ pkgs.shade ];  # or custom derivation
}
```

**Config location**: `~/.config/shade/config.json` (generated by Nix)

**Rebuild to apply changes**:
```bash
just rebuild  # or: darwin-rebuild switch --flake ~/.dotfiles
```

### Config File Format

Shade reads `~/.config/shade/config.json` at startup:

```json
{
  "window": {
    "width": 0.5,
    "height": 0.6,
    "padding": 0,
    "decorations": false
  },
  "nvim": {
    "socket": "~/.local/state/shade/nvim.sock",
    "command": "nvim --listen ~/.local/state/shade/nvim.sock"
  },
  "llm": {
    "enabled": true,
    "backend": "mlx",
    "model": "mlx-community/Qwen3-8B-Instruct-4bit",
    "preset": "quality",
    "auto_summarize": true,
    "auto_categorize": true,
    "preload": false,
    "idle_timeout": 300
  },
  "capture": {
    "ocr_enabled": true,
    "working_directory": "$notes_home/captures"
  }
}
```

### CLI Overrides

CLI flags override config file settings:

```bash
shade --llm-backend mlx                                    # Use MLX backend (default)
shade --llm-backend ollama                                 # Use Ollama HTTP backend
shade --llm-model "mlx-community/Qwen3-8B-Instruct-bf16"   # Override model
shade --llm-preset premium                                 # Use premium preset
shade --llm-preload                                        # Load model at startup
shade --no-llm                                             # Disable LLM entirely
```

### Environment Variables

Environment variables override both config and CLI (highest priority):

```bash
SHADE_LLM_BACKEND="mlx"
SHADE_LLM_MODEL="mlx-community/Qwen3-8B-Instruct-bf16"
SHADE_LLM_PRESET="premium"
SHADE_LLM_PRELOAD=1
SHADE_NO_LLM=1
```

### Configuration Precedence

```
Environment Variables  (highest)
        ↓
CLI Flags
        ↓
~/.config/shade/config.json
        ↓
Built-in Defaults      (lowest)
```

---

## Nix Flake Integration

### Adding Shade to Your Dotfiles

Shade is packaged as a Nix flake. Add it to your dotfiles flake inputs:

**File**: `~/.dotfiles/flake.nix`

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    # ... other inputs ...

    # Shade - floating terminal panel
    shade = {
      url = "github:megalithic/shade";
      inputs.nixpkgs.follows = "nixpkgs";  # Use same nixpkgs
    };
  };

  outputs = { self, nixpkgs, shade, ... }@inputs: {
    # Pass shade to your darwin/home-manager config
    darwinConfigurations."your-hostname" = darwin.lib.darwinSystem {
      specialArgs = { inherit inputs; };
      modules = [ ./hosts/your-hostname ];
    };
  };
}
```

### Home-Manager Module

**File**: `~/.dotfiles/home/programs/shade.nix`

```nix
{ config, pkgs, lib, inputs, ... }:
let
  # Get shade from flake input
  shadePkg = inputs.shade.packages.${pkgs.system}.default;

  # Configuration
  shadeConfig = {
    window = {
      width = 0.5;
      height = 0.6;
      padding = 0;
      decorations = false;
    };

    nvim = {
      socket = "~/.local/state/shade/nvim.sock";
      command = "nvim --listen ~/.local/state/shade/nvim.sock";
    };

    llm = {
      enabled = true;
      backend = "mlx";
      model = "mlx-community/Qwen3-8B-Instruct-4bit";
      preset = "quality";
      auto_summarize = true;
      auto_categorize = true;
      preload = false;
      idle_timeout = 300;
    };

    capture = {
      ocr_enabled = true;
      working_directory = config.home.sessionVariables.notes_home + "/captures";
    };
  };
in
{
  # Install shade binary from flake
  home.packages = [ shadePkg ];

  # Generate config file
  xdg.configFile."shade/config.json" = {
    text = builtins.toJSON shadeConfig;
  };

  # Create state directory
  home.activation.shadeStateDir = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    mkdir -p ~/.local/state/shade
  '';
}
```

### Flake Lock Update

After adding the input, update the lock file:

```bash
cd ~/.dotfiles
nix flake lock --update-input shade
just rebuild
```

### Shade Flake Outputs

The shade flake exposes:

| Output | Description |
|--------|-------------|
| `packages.<system>.default` | Shade binary |
| `packages.<system>.shade` | Alias for default |
| `packages.<system>.ghosttykit` | libghostty static library |
| `devShells.<system>.default` | Full dev environment (with Zig) |
| `devShells.<system>.lite` | Lite dev environment (pre-built GhosttyKit) |

### Updating Shade

```bash
# Update to latest shade
cd ~/.dotfiles
nix flake lock --update-input shade

# Rebuild system
just rebuild

# Verify version
shade --version
```

---

## Implementation Tasks

### Phase 0: Configuration Infrastructure
- [ ] **CFG-1**: Implement ShadeConfig.swift (parse ~/.config/shade/config.json)
- [ ] **CFG-2**: Create config types (ShadeConfig, LLMConfig, WindowConfig, etc.)
- [ ] **CFG-3**: Add CLI argument parsing that merges with config file
- [ ] **CFG-4**: Create `~/.dotfiles/home/programs/shade.nix` module

### Phase 1: MLX Foundation
- [ ] **MLX-1**: Add mlx-swift-lm dependency to Package.swift
- [ ] **MLX-2**: Create MLXInferenceEngine actor with lazy loading
- [ ] **MLX-3**: Implement basic `summarize()` method
- [ ] **MLX-4**: Add `--llm-backend`, `--llm-model`, and `--no-llm` CLI flags
- [ ] **MLX-5**: Test with Qwen3-8B-Instruct-4bit model (quality default)

### Phase 2: Async Pipeline Integration
- [ ] **ASYNC-1**: Implement AsyncEnrichmentManager (background task coordination)
- [ ] **ASYNC-2**: Insert placeholders via nvim RPC after OCR completes
- [ ] **ASYNC-3**: Replace placeholders when LLM enrichment completes
- [ ] **ASYNC-4**: Add virtual text "⏳ Generating..." indicator while pending
- [ ] **ASYNC-5**: Handle edge cases (buffer closed, placeholder edited, etc.)

### Phase 2b: RPC & Methods
- [ ] **MLX-6**: Wire MLX into OCR pipeline (trigger async enrichment)
- [ ] **MLX-7**: Implement `categorize()` method with context awareness
- [ ] **MLX-8**: Add RPC commands to ShadeServer (summarize, categorize)
- [ ] **MLX-9**: Add model status and memory management RPC commands

### Phase 3: Polish
- [ ] **MLX-10**: Auto-download model on first use (with progress)
- [ ] **MLX-11**: Add model caching to ~/.cache/huggingface/ (MLX default)
- [ ] **MLX-12**: Implement model unloading after idle timeout
- [ ] **MLX-13**: Add Ollama fallback for when MLX is disabled

### Future: Vision-Language
- [ ] **VLM-1**: Add MLXVLM dependency
- [ ] **VLM-2**: Implement direct image understanding (skip OCR)
- [ ] **VLM-3**: Compare VLM vs VisionKit+LLM quality/speed

---

## Dependencies & Compatibility

### Required
- macOS 14.0+ (Sonnet) for MLX
- Apple Silicon (M1/M2/M3/M4/M5)
- Swift 5.9+

### Package Dependencies
```
mlx-swift-lm >= 2.29.1
  └── mlx-swift >= 0.21.0
      └── Metal framework
```

### Disk Space
- Model downloads go to HuggingFace cache (~/.cache/huggingface/)
- First model download: 0.8-4.3 GB depending on model
- Shade binary size increase: ~5-10 MB (MLX framework)

---

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Model download on first use | Slow first experience | Pre-download option, progress indicator |
| Memory pressure from model | System slowdown | Lazy loading, idle unload, model size options |
| MLX API changes | Build breaks | Pin to specific version, test on updates |
| Model quality issues | Poor summaries | Allow model selection, Ollama fallback |

---

## Success Metrics

1. **Latency**: First token < 100ms, full summary < 2s
2. **Memory**: Idle < 100MB, active < 4GB (3B model)
3. **Quality**: Summaries are coherent and accurate (manual review)
4. **Reliability**: No crashes, graceful degradation

---

## References

- [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm)
- [MLX Swift Examples](https://github.com/ml-explore/mlx-swift-examples)
- [MLX Community Models](https://huggingface.co/mlx-community)
- [WWDC25: Explore LLMs on Apple Silicon](https://developer.apple.com/videos/play/wwdc2025/298/)
- [Run Local LLMs with Swift and MLX](https://www.blog.brightcoding.dev/2025/07/18/run-local-llms-at-blazing-speed-on-your-mac-with-swift-and-mlx/)

---

## Appendix: Model Comparison

### Benchmark: Summarization Task (M2 Max, 64GB)

| Model | Load Time | First Token | 100 tokens | Quality (1-5) |
|-------|-----------|-------------|------------|---------------|
| Llama-3.2-3B-4bit | ~1s | ~50ms | ~0.8s | 3.5 |
| Qwen3-4B-4bit | ~2s | ~60ms | ~1.2s | 4.0 |
| Qwen3-8B-4bit | ~4s | ~80ms | ~2.0s | 4.5 |
| Mistral-7B-4bit | ~3s | ~70ms | ~1.5s | 4.0 |

*Note: Benchmarks are estimates based on community reports. Actual results may vary.*
