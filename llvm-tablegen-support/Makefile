
LLVM_CONFIG ?= /usr/local/opt/llvm/bin/llvm-config

# Required for X86DisassemblerDecoder.h
LLVM_SOURCE_ROOT ?= ${HOME}/galois/vadds/llvm-stuff/llvm

llvm-tablegen-support: src/main.cpp
	clang++ -g -O3 $^ -I ${LLVM_SOURCE_ROOT}/lib/Target/X86/Disassembler `${LLVM_CONFIG} --cxxflags --ldflags --system-libs --libs x86` -o $@
