// ElevenLabs API Proxy Edge Function
// Keeps the ElevenLabs API key secure on the server

import { serve } from "https://deno.land/std@0.168.0/http/server.ts"

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

serve(async (req) => {
  // Handle CORS preflight requests
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const apiKey = Deno.env.get('ELEVENLABS_API_KEY')
    if (!apiKey) {
      throw new Error('ELEVENLABS_API_KEY not configured')
    }

    const url = new URL(req.url)
    const endpoint = url.searchParams.get('endpoint') || 'sound-generation'
    
    let elevenlabsUrl: string
    switch (endpoint) {
      case 'sound-generation':
        elevenlabsUrl = 'https://api.elevenlabs.io/v1/sound-generation'
        break
      case 'music':
        elevenlabsUrl = 'https://api.elevenlabs.io/v1/music'
        break
      case 'subscription':
        elevenlabsUrl = 'https://api.elevenlabs.io/v1/user/subscription'
        break
      default:
        throw new Error(`Unknown endpoint: ${endpoint}`)
    }

    // For subscription endpoint, it's a GET request
    if (endpoint === 'subscription') {
      const response = await fetch(elevenlabsUrl, {
        method: 'GET',
        headers: {
          'xi-api-key': apiKey,
        },
      })

      const data = await response.json()
      return new Response(JSON.stringify(data), {
        status: response.status,
        headers: {
          ...corsHeaders,
          'Content-Type': 'application/json',
        },
      })
    }

    // For sound/music generation, it's a POST request that returns audio
    const requestBody = await req.json()
    
    const response = await fetch(elevenlabsUrl, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'xi-api-key': apiKey,
      },
      body: JSON.stringify(requestBody),
    })

    if (!response.ok) {
      const errorText = await response.text()
      return new Response(
        JSON.stringify({ error: errorText }),
        {
          status: response.status,
          headers: {
            ...corsHeaders,
            'Content-Type': 'application/json',
          },
        }
      )
    }

    // Return audio data as base64 to avoid binary transfer issues
    const audioBuffer = await response.arrayBuffer()
    const base64Audio = btoa(String.fromCharCode(...new Uint8Array(audioBuffer)))

    return new Response(
      JSON.stringify({ audio: base64Audio }),
      {
        status: 200,
        headers: {
          ...corsHeaders,
          'Content-Type': 'application/json',
        },
      }
    )
  } catch (error) {
    console.error('ElevenLabs proxy error:', error)
    return new Response(
      JSON.stringify({ error: error.message }),
      {
        status: 500,
        headers: {
          ...corsHeaders,
          'Content-Type': 'application/json',
        },
      }
    )
  }
})
