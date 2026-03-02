/// Focus layers ordered by priority (highest first)
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum FocusLayer {
    Global = 0,
    Chat = 1,
    Input = 2,
    Completions = 3,
    Dialog = 4,
}

/// Stack-based focus manager.
/// Events dispatch top-down. First Consumed stops propagation.
pub struct FocusStack {
    layers: Vec<FocusLayer>,
}

impl FocusStack {
    pub fn new() -> Self {
        Self {
            layers: vec![FocusLayer::Global, FocusLayer::Chat, FocusLayer::Input],
        }
    }

    /// Push a layer (e.g., when completions popup opens)
    pub fn push(&mut self, layer: FocusLayer) {
        if !self.layers.contains(&layer) {
            self.layers.push(layer);
            self.layers.sort_by(|a, b| b.cmp(a)); // highest priority first
        }
    }

    /// Remove a layer (e.g., when completions popup closes)
    pub fn pop(&mut self, layer: FocusLayer) {
        self.layers.retain(|l| *l != layer);
    }

    /// Get the current top focus layer
    pub fn top(&self) -> FocusLayer {
        self.layers.first().copied().unwrap_or(FocusLayer::Global)
    }

    /// Get ordered layers for event dispatch (highest priority first)
    pub fn dispatch_order(&self) -> &[FocusLayer] {
        &self.layers
    }

    /// Check if a specific layer is active
    pub fn has(&self, layer: FocusLayer) -> bool {
        self.layers.contains(&layer)
    }
}

impl Default for FocusStack {
    fn default() -> Self {
        Self::new()
    }
}
