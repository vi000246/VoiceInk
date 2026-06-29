# Spec Roadmap

> Auto-updated index. Last updated: 2026-06-29
>
> **AI Agents**: Read this file first to decide which specs to load. Load only what's relevant to
> your task to avoid context bloat.

## Module Index

| Module | Spec | Domain Layer | Description | Sub-modules |
|--------|------|--------------|-------------|-------------|
| recorder-automation | [recorder-automation.spec.md](./recorder-automation.spec.md) | Supporting Domain | Watches recorder volume mounts, auto-imports audio into the existing transcription queue, classifies each transcript, routes to a category's CustomPrompt, and exports analysis Markdown to an Obsidian vault. | — |

## Loading Guide

| Task Type | Load These Specs |
|-----------|-----------------|
| 實作特定子模組功能 | 該子模組 spec + parent spec |
| 跨模組整合 | 相關模組各自的 root spec |
| 第一次理解系統 | 先讀本 SPEC_ROADMAP，再按需載入 |

## Recent Feature Changes

| Date | Module | Feature SRS | One-line Summary |
|------|--------|-------------|-----------------|
| 2026-06-29 | recorder-automation | [auto-import-template-routing.srs.md](../srs/recorder-automation-auto-import-template-routing.srs.md) | Plug in a recorder → auto-import, transcribe, classify, apply the category's template, and export an analysis note to the vault. |
