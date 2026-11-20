package geo

func Area(w, h int) int {
	return w * h * secretScale(1)
}

func secretScale(x int) int {
	return x * 2
}
