.PHONY: lint format

format: Sushitrain/*.swift
	swift-format format -r -i .

lint: Sushitrain/*.swift
	swift-format lint -r .