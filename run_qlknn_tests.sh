#!/bin/bash

# QLKNN Tests Runner
# Sets up Python environment for PythonKit before running tests

set -e

# Configure Python library path for PythonKit
export PYTHON_LIBRARY="/Library/Frameworks/Python.framework/Versions/3.12/lib/libpython3.12.dylib"
export PYTHONPATH="/Library/Frameworks/Python.framework/Versions/3.12/lib/python3.12/site-packages"

# Verify Python setup
echo "🐍 Python Configuration:"
echo "  PYTHON_LIBRARY: $PYTHON_LIBRARY"
echo "  PYTHONPATH: $PYTHONPATH"
echo ""

# Verify fusion_surrogates is installed
if python3 -c "import fusion_surrogates" 2>/dev/null; then
    echo "✅ fusion_surrogates is installed"
else
    echo "❌ fusion_surrogates is NOT installed"
    echo ""
    echo "Please install fusion_surrogates:"
    echo "  pip install fusion-surrogates"
    exit 1
fi

echo ""
echo "🧪 Running QLKNN Tests..."
echo ""

# Run QLKNN tests with environment variables
swift test --filter QLKNNTransportModelTests

echo ""
echo "✅ Tests completed"
