# WebSocket Development Guide

Channel handlers should authenticate the socket, authorize topic joins, validate envelopes, delegate to application commands, and return stable errors. They should not contain database transaction logic or provider calls.

Every durable event must identify its replay source and ordering scope. Every ephemeral event must be safe to lose, duplicate, or reorder.
