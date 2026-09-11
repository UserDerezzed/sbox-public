using Sandbox.Services;

namespace ServiceTests;

[TestClass]
public class BenchmarkSamplerTests
{
	/// <summary>
	/// A scene that only gets a handful of frames into its window used to throw from GetResults - P5 indexed [-1] -
	/// which dropped the whole scene from the benchmark results.
	/// </summary>
	[TestMethod]
	public void FewSamplesStillGiveResults()
	{
		var sampler = new BenchmarkSystem.Sampler( "FrameTimeMs", null );
		sampler.AddSample( 30.0 );
		sampler.AddSample( 10.0 );
		sampler.AddSample( 20.0 );

		var result = sampler.GetResults();

		Assert.AreEqual( 10.0, result.P5 );
		Assert.AreEqual( 20.0, result.P50 );
		Assert.AreEqual( 30.0, result.P99 );
		Assert.AreEqual( 3.0, result.Count );
	}

	[TestMethod]
	public void NoSamplesGiveZeroes()
	{
		var result = new BenchmarkSystem.Sampler( "Empty", null ).GetResults();

		Assert.AreEqual( 0.0, result.P5 );
		Assert.AreEqual( 0.0, result.P50 );
		Assert.AreEqual( 0.0, result.P99_9 );
		Assert.AreEqual( 0.0, result.Count );
	}
}
