/******************************************************************************
 * Copyright (c) 2013, NVIDIA CORPORATION.  All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *     * Redistributions of source code must retain the above copyright
 *       notice, this list of conditions and the following disclaimer.
 *     * Redistributions in binary form must reproduce the above copyright
 *       notice, this list of conditions and the following disclaimer in the
 *       documentation and/or other materials provided with the distribution.
 *     * Neither the name of the NVIDIA CORPORATION nor the
 *       names of its contributors may be used to endorse or promote products
 *       derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL NVIDIA CORPORATION BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 ******************************************************************************/

/******************************************************************************
 *
 * Code and text by Sean Baxter, NVIDIA Research
 * See http://nvlabs.github.io/moderngpu for repository and documentation.
 *
 ******************************************************************************/

#pragma once

#include "../sgpuhost.cuh"
#include "../kernels/merge.cuh"

namespace sgpu {

template<typename Tuning, bool HasValues, typename KeyIt1, typename KeyIt2,
	typename ValIt1, typename ValIt2, typename Comp>
SGPU_LAUNCH_BOUNDS void KernelBlocksort(int numTiles, KeyIt1 keysSource_global,
	ValIt1 valsSource_global, int count, KeyIt2 keysDest_global,
	ValIt2 valsDest_global, Comp comp) {

	typedef SGPU_LAUNCH_PARAMS Params;
	typedef typename std::iterator_traits<KeyIt1>::value_type KeyType;
	typedef typename std::iterator_traits<ValIt1>::value_type ValType;

	const int NT = Params::NT;
	const int VT = Params::VT;
	const int NV = NT * VT;
	union Shared {
		KeyType keys[NT * (VT + 1)];
		ValType values[NV];
	};
	__shared__ Shared shared;

	int tid = threadIdx.x;

	for(int block = blockIdx.x; block < numTiles; block += gridDim.x) {
		__syncthreads();

		int gid = NV * block;
		int count2 = min(NV, count - gid);

		// Load the values into thread order.
		ValType threadValues[VT];
		if(HasValues) {
			DeviceGlobalToShared<NT, VT>(count2, valsSource_global + gid, tid,
				shared.values);
			DeviceSharedToThread<VT>(shared.values, tid, threadValues);
		}

		// Load keys into shared memory and transpose into register in thread order.
		KeyType threadKeys[VT];
		DeviceGlobalToShared<NT, VT>(count2, keysSource_global + gid, tid,
			shared.keys);
		DeviceSharedToThread<VT>(shared.keys, tid, threadKeys);

		// If we're in the last tile, set the uninitialized keys for the thread with
		// a partial number of keys.
		int first = VT * tid;
		if(first + VT > count2 && first < count2) {
			KeyType maxKey = threadKeys[0];
			#pragma unroll
			for(int i = 1; i < VT; ++i)
				if(first + i < count2)
					maxKey = comp(maxKey, threadKeys[i]) ? threadKeys[i] : maxKey;

			// Fill in the uninitialized elements with max key.
			#pragma unroll
			for(int i = 0; i < VT; ++i)
				if(first + i >= count2) threadKeys[i] = maxKey;
		}

		CTAMergesort<NT, VT, true, HasValues>(threadKeys, threadValues, shared.keys,
			shared.values, count2, tid, comp);

		// Store the sorted keys to global.
		DeviceSharedToGlobal<NT, VT>(count2, shared.keys, tid,
			keysDest_global + gid);

		if(HasValues) {
			DeviceThreadToShared<VT>(threadValues, tid, shared.values);
			DeviceSharedToGlobal<NT, VT>(count2, shared.values, tid,
				valsDest_global + gid);
		}
	}
}

////////////////////////////////////////////////////////////////////////////////
// MergesortKeys

template<typename T, typename Comp>
SGPU_HOST void MergesortKeys(T* data_global, int count, Comp comp,
	CudaContext& context) {

	typedef LaunchBoxVT<
		256, 11, 0,
		256, (sizeof(T) > 4) ? 7 : 11, 0,
		256, (sizeof(T) > 4) ? 7 : 11, 0
	> Tuning;
	int2 launch = Tuning::GetLaunchParams(context);

	const int NV = launch.x * launch.y;
	int numTiles = SGPU_DIV_UP(count, NV);
	int numPasses = FindLog2(numTiles, true);

	int maxBlocks = context.MaxGridSize();
	int numBlocks = min(numTiles, maxBlocks);

	SGPU_MEM(T) destDevice = context.Malloc<T>(count);
	T* source = data_global;
	T* dest = destDevice->get();

	KernelBlocksort<Tuning, false>
		<<<numBlocks, launch.x, 0, context.Stream()>>>(numTiles, source,
		(const int*)0, count, (1 & numPasses) ? dest : source, (int*)0, comp);
	SGPU_SYNC_CHECK("KernelBlocksort");

	if(1 & numPasses) std::swap(source, dest);

	for(int pass = 0; pass < numPasses; ++pass) {
		int coop = 2<< pass;
		SGPU_MEM(int) partitionsDevice = MergePathPartitions<SgpuBoundsLower>(
			source, count, source, 0, NV, coop, comp, context);

		KernelMerge<Tuning, false, false>
			<<<numBlocks, launch.x, 0, context.Stream()>>>(numTiles, source,
			(const int*)0, count, source, (const int*)0, 0,
			partitionsDevice->get(), coop, dest, (int*)0, comp);
		SGPU_SYNC_CHECK("KernelMerge");

		std::swap(dest, source);
	}
}
template<typename T>
SGPU_HOST void MergesortKeys(T* data_global, int count, CudaContext& context) {
	MergesortKeys(data_global, count, sgpu::less<T>(), context);
}

////////////////////////////////////////////////////////////////////////////////
// MergesortPairs

template<typename KeyType, typename ValType, typename Comp>
SGPU_HOST void MergesortPairs(KeyType* keys_global, ValType* values_global,
	int count, Comp comp, CudaContext& context) {

	typedef LaunchBoxVT<
		256, 11, 0,
		256, (sizeof(KeyType) > 4) ? 7 : 11, 0,
		256, (sizeof(KeyType) > 4) ? 7 : 11, 0
	> Tuning;
	int2 launch = Tuning::GetLaunchParams(context);

	const int NV = launch.x * launch.y;
	int numTiles = SGPU_DIV_UP(count, NV);
	int numPasses = FindLog2(numTiles, true);

	int maxBlocks = context.MaxGridSize();
	int numBlocks = min(numTiles, maxBlocks);

	SGPU_MEM(KeyType) keysDestDevice = context.Malloc<KeyType>(count);
	SGPU_MEM(ValType) valsDestDevice = context.Malloc<ValType>(count);
	KeyType* keysSource = keys_global;
	KeyType* keysDest = keysDestDevice->get();
	ValType* valsSource = values_global;
	ValType* valsDest = valsDestDevice->get();

	KernelBlocksort<Tuning, true><<<numBlocks, launch.x, 0, context.Stream()>>>(
		numTiles, keysSource, valsSource, count,
		(1 & numPasses) ? keysDest : keysSource,
		(1 & numPasses) ? valsDest : valsSource, comp);
	SGPU_SYNC_CHECK("KernelBlocksort");

	if(1 & numPasses) {
		std::swap(keysSource, keysDest);
		std::swap(valsSource, valsDest);
	}

	for(int pass = 0; pass < numPasses; ++pass) {
		int coop = 2<< pass;
		SGPU_MEM(int) partitionsDevice = MergePathPartitions<SgpuBoundsLower>(
			keysSource, count, keysSource, 0, NV, coop, comp, context);

		KernelMerge<Tuning, true, false>
			<<<numBlocks, launch.x, 0, context.Stream()>>>(numTiles, keysSource,
			valsSource, count, keysSource, valsSource, 0,
			partitionsDevice->get(), coop, keysDest, valsDest, comp);
		SGPU_SYNC_CHECK("KernelMerge");

		std::swap(keysDest, keysSource);
		std::swap(valsDest, valsSource);
	}
}
template<typename KeyType, typename ValType>
SGPU_HOST void MergesortPairs(KeyType* keys_global, ValType* values_global,
	int count, CudaContext& context) {
	MergesortPairs(keys_global, values_global, count, sgpu::less<KeyType>(),
		context);
}

template<typename KeyType, typename Comp>
SGPU_HOST void MergesortIndices(KeyType* keys_global, int* values_global,
	int count, Comp comp, CudaContext& context) {

	const int NT = 256;
	const int VT = 11;
	typedef LaunchBoxVT<NT, VT> Tuning;
	int2 launch = Tuning::GetLaunchParams(context);

	const int NV = launch.x * launch.y;
	int numTiles = SGPU_DIV_UP(count, NV);
	int numPasses = FindLog2(numTiles, true);

	int maxBlocks = context.MaxGridSize();
	int numBlocks = min(numTiles, maxBlocks);

	SGPU_MEM(KeyType) keysDestDevice = context.Malloc<KeyType>(count);
	SGPU_MEM(int) valsDestDevice = context.Malloc<int>(count);
	KeyType* keysSource = keys_global;
	KeyType* keysDest = keysDestDevice->get();
	int* valsSource = values_global;
	int* valsDest = valsDestDevice->get();

	KernelBlocksort<Tuning, true><<<numBlocks, launch.x, 0, context.Stream()>>>(
		numTiles, keysSource, sgpu::counting_iterator<int>(0), count,
		(1 & numPasses) ? keysDest : keysSource,
		(1 & numPasses) ? valsDest : valsSource, comp);
	SGPU_SYNC_CHECK("KernelBlocksort");

	if(1 & numPasses) {
		std::swap(keysSource, keysDest);
		std::swap(valsSource, valsDest);
	}

	for(int pass = 0; pass < numPasses; ++pass) {
		int coop = 2<< pass;
		SGPU_MEM(int) partitionsDevice = MergePathPartitions<SgpuBoundsLower>(
			keysSource, count, keysSource, 0, NV, coop, comp, context);

		KernelMerge<Tuning, true, false>
			<<<numBlocks, launch.x, 0, context.Stream()>>>(numTiles, keysSource,
			valsSource, count, keysSource, valsSource, 0,
			partitionsDevice->get(), coop, keysDest, valsDest, comp);
		SGPU_SYNC_CHECK("KernelMerge");

		std::swap(keysDest, keysSource);
		std::swap(valsDest, valsSource);
	}
}
template<typename KeyType>
SGPU_HOST void MergesortIndices(KeyType* keys_global, int* values_global,
	int count, CudaContext& context) {
	MergesortIndices(keys_global, values_global, count, sgpu::less<KeyType>(),
		context);
}

} // namespace sgpu
