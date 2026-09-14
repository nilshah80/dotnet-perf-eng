package performance

import (
	"fmt"
	"math"
)

type Shard struct {
	ID     string
	Weight float64
	Load   float64
}

type Aggregate struct {
	Requests   float64
	Failures   float64
	Histogram  []int
	Saturation map[string]bool
	Percentile map[string]float64
}

func PlanShards(n int, total float64) ([]Shard, error) {
	if n < 1 {
		return nil, fmt.Errorf("shard count must be positive")
	}
	shards := make([]Shard, n)
	share := total / float64(n)
	for i := 0; i < n; i++ {
		shards[i] = Shard{ID: fmt.Sprintf("shard-%d", i+1), Weight: 1 / float64(n), Load: share}
	}
	return shards, nil
}

func Merge(parts []Aggregate) (Aggregate, error) {
	out := Aggregate{Saturation: map[string]bool{}, Percentile: map[string]float64{}}
	for i, part := range parts {
		out.Requests += part.Requests
		out.Failures += part.Failures
		if i == 0 {
			out.Histogram = append([]int(nil), part.Histogram...)
		} else if len(part.Histogram) != len(out.Histogram) {
			return Aggregate{}, fmt.Errorf("histogram shape mismatch: %d vs %d", len(part.Histogram), len(out.Histogram))
		} else {
			for j := range part.Histogram {
				out.Histogram[j] += part.Histogram[j]
			}
		}
		for k, v := range part.Saturation {
			out.Saturation[k] = out.Saturation[k] || v
		}
	}
	if len(out.Histogram) > 0 {
		out.Percentile["p95"] = percentileFromHistogram(out.Histogram, 0.95)
	}
	return out, nil
}

func percentileFromHistogram(hist []int, p float64) float64 {
	total := 0
	for _, count := range hist {
		total += count
	}
	if total == 0 {
		return 0
	}
	rank := int(math.Ceil(p*float64(total))) - 1
	if rank < 0 {
		rank = 0
	}
	acc := 0
	for i, count := range hist {
		acc += count
		if acc > rank {
			return float64(i)
		}
	}
	return float64(len(hist) - 1)
}

func RejectPercentileAverage(values []float64) float64 {
	max := 0.0
	for _, v := range values {
		if v > max {
			max = v
		}
	}
	return max
}

func JMeterShardSafe(controllerLoad, intended float64) error {
	if math.Abs(controllerLoad-intended) > 0.01*intended && controllerLoad > intended {
		return fmt.Errorf("JMeter sharding multiplied intended load")
	}
	return nil
}
