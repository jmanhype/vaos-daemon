/// Command history with navigation
pub struct History {
    entries: Vec<String>,
    index: Option<usize>,
    max_size: usize,
}

impl History {
    pub fn new(max_size: usize) -> Self {
        Self {
            entries: Vec::new(),
            index: None,
            max_size,
        }
    }

    pub fn push(&mut self, entry: String) {
        // Don't add duplicates of the last entry
        if self.entries.last().map(|e| e.as_str()) == Some(&entry) {
            return;
        }
        self.entries.push(entry);
        if self.entries.len() > self.max_size {
            self.entries.remove(0);
        }
        self.index = None;
    }

    pub fn prev(&mut self) -> Option<&str> {
        if self.entries.is_empty() {
            return None;
        }
        let idx = match self.index {
            None => self.entries.len() - 1,
            Some(0) => 0,
            Some(i) => i - 1,
        };
        self.index = Some(idx);
        self.entries.get(idx).map(|s| s.as_str())
    }

    pub fn next(&mut self) -> Option<&str> {
        match self.index {
            None => None,
            Some(i) => {
                if i + 1 >= self.entries.len() {
                    self.index = None;
                    None
                } else {
                    self.index = Some(i + 1);
                    self.entries.get(i + 1).map(|s| s.as_str())
                }
            }
        }
    }

    pub fn reset_navigation(&mut self) {
        self.index = None;
    }
}
